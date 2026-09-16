import assert from "node:assert/strict"
import { mkdtempSync, writeFileSync } from "node:fs"
import type { AddressInfo } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { after, before, test } from "node:test"
import { createApi } from "./api.ts"
import { loadConfig } from "./config.ts"
import { Store } from "./db.ts"

/// A real server over a real SQLite database. Nothing here is stood in for: the routes are
/// exercised the way the app and the keeper exercise them.

const BORROWER = "0xd7e3c3ca8aec672e45269bcae584a93b312bc2bd"
const ASSET = "0xe848360b1baeb68b080c7b2731095ba1c21d0ada"
const POOL = "0xc7dc6ca56dddf387cf5fd6dfdf4e728a7878df38"

const directory = mkdtempSync(join(tmpdir(), "safix-api-"))
const configPath = join(directory, "config.json")
// A real port in the file, because the config rightly refuses port 0; the server itself binds to
// 0 below so the test never collides with anything already listening.
writeFileSync(configPath, JSON.stringify({ rpcUrl: "https://example.invalid/rpc", poolAddress: POOL, port: 8080 }))

const store = new Store(":memory:")
const config = loadConfig(configPath, {})
const server = createApi(config, store, () => ({ head: 200n, lastPassAt: 1_700_000_000, lastError: null }))

let origin = ""

before(async () => {
  store.writeBatch(
    [
      {
        blockNumber: 100n,
        logIndex: 0,
        txHash: "0xaaa",
        timestamp: 1_700_000_000,
        source: "pool",
        address: POOL,
        name: "Deposited",
        actor: BORROWER,
        asset: null,
        args: { provider: BORROWER, amount: "1000000000" }
      },
      {
        blockNumber: 101n,
        logIndex: 0,
        txHash: "0xbbb",
        timestamp: 1_700_000_100,
        source: "pool",
        address: POOL,
        name: "Drawn",
        actor: BORROWER,
        asset: ASSET,
        args: { borrower: BORROWER, asset: ASSET, amount: "500000000", fee: "2500000" }
      }
    ],
    [],
    150n
  )
  store.writePosition({
    borrower: BORROWER,
    asset: ASSET,
    collateral: 80n * 10n ** 18n,
    debt: 502_500_000n,
    principal: 500_000_000n,
    openedBlock: 100n,
    lastBlock: 101n
  })
  await new Promise<void>(resolve => server.listen(0, resolve))
  origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})

after(() => {
  server.close()
  store.close()
})

const get = async (path: string) => {
  const response = await fetch(`${origin}${path}`)
  return { status: response.status, headers: response.headers, body: await response.json() }
}

test("/health answers whether the process is up, not whether it is current", async () => {
  // A restart policy watches this. Conflating liveness with freshness makes a host kill an index
  // that is merely behind, which is the moment it most needs to be left alone to catch up.
  const { status, body } = await get("/health")
  assert.equal(status, 200)
  assert.equal((body as { ok: boolean }).ok, true)
})

test("/status reports the lag the keeper refuses to trust past", async () => {
  const { body } = await get("/status")
  const status = body as { cursor: number; head: number; blocksBehind: number; events: number }
  assert.equal(status.cursor, 150)
  assert.equal(status.head, 200)
  assert.equal(status.blocksBehind, 50)
  assert.equal(status.events, 2)
})

test("/positions is what the keeper reads", async () => {
  const { body } = await get("/positions")
  const result = body as { count: number; positions: { borrower: string; asset: string; debt: string }[] }
  assert.equal(result.count, 1)
  assert.equal(result.positions[0].borrower, BORROWER)
  assert.equal(result.positions[0].debt, "502500000")
})

test("/history serves a wallet's own rows, newest first", async () => {
  const { body } = await get(`/history/${BORROWER}`)
  const result = body as { count: number; events: { name: string }[] }
  assert.equal(result.count, 2)
  assert.deepEqual(result.events.map(entry => entry.name), ["Drawn", "Deposited"])
})

test("a wallet with no history gets an empty list, not an error", async () => {
  // The app tells "nothing here" apart from "could not read" by this distinction, so a 404 or a
  // 500 for an unknown address would put the wrong message on the screen.
  const { status, body } = await get("/history/0x0000000000000000000000000000000000000001")
  assert.equal(status, 200)
  assert.equal((body as { count: number }).count, 0)
})

test("CORS is open, because every row is already public in the chain's logs", async () => {
  const { headers } = await get("/status")
  assert.equal(headers.get("access-control-allow-origin"), "*")
})

test("it is read-only: a write method is refused", async () => {
  for (const method of ["POST", "PUT", "DELETE", "PATCH"]) {
    const response = await fetch(`${origin}/status`, { method })
    assert.equal(response.status, 405, `${method} must not be served`)
  }
})

test("there is no route that lists attested subjects", async () => {
  // A list of attested wallets is exactly the profile docs/passport-policy.md says not to build.
  // /attestations answers only for an address the caller already names.
  const { status, body } = await get("/attestations")
  assert.equal(status, 404)
  const routes = (body as { routes: string[] }).routes
  assert.equal(
    routes.some(route => /attestations$|subjects|attested/i.test(route.replace("/attestations/:address", ""))),
    false
  )
  assert.ok(routes.includes("/attestations/:address"))
})

test("an unknown route lists the ones that exist", async () => {
  const { status, body } = await get("/nope")
  assert.equal(status, 404)
  assert.ok(Array.isArray((body as { routes: string[] }).routes))
})

test("limit is capped, so one request cannot ask for the whole table", async () => {
  const { body } = await get(`/history/${BORROWER}?limit=999999`)
  assert.ok((body as { count: number }).count <= 500)
})
