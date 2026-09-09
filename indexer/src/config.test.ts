import assert from "node:assert/strict"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { loadConfig } from "./config.ts"

const directory = mkdtempSync(join(tmpdir(), "safix-indexer-"))

const write = (config: unknown): string => {
  const path = join(directory, `config-${Math.random().toString(36).slice(2)}.json`)
  writeFileSync(path, JSON.stringify(config))
  return path
}

const valid = {
  rpcUrl: "https://rpc.testnet.chain.robinhood.com",
  poolAddress: "0xc7dc6ca56dddf387cf5fd6dfdf4e728a7878df38",
  deployBlock: 114962671
}

test("a minimal config loads and fills in every default", () => {
  const config = loadConfig(write(valid), {})
  assert.equal(config.deployBlock, 114962671n)
  assert.equal(config.deskAddress, null)
  assert.equal(config.registryAddress, null)
  assert.equal(config.timestampBatchSize, 100)
  assert.ok(config.intervalMs > 0)
  assert.ok(config.reorgDepthBlocks > 0n)
})

test("the pool address is checksummed, so a lower-cased config still matches a chain read", () => {
  const config = loadConfig(write(valid), {})
  assert.equal(config.poolAddress, "0xc7dc6cA56dDDf387cF5FD6dfdF4e728a7878DF38")
})

test("a zero desk or registry address is absent, not a contract at zero", () => {
  const config = loadConfig(
    write({ ...valid, deskAddress: "0x0000000000000000000000000000000000000000", registryAddress: "" }),
    {}
  )
  assert.equal(config.deskAddress, null)
  assert.equal(config.registryAddress, null)
})

test("it refuses a pool address that is not one", () => {
  assert.throws(() => loadConfig(write({ ...valid, poolAddress: "not-an-address" }), {}), /poolAddress/)
  assert.throws(
    () => loadConfig(write({ ...valid, poolAddress: "0x0000000000000000000000000000000000000000" }), {}),
    /zero address/
  )
})

test("it refuses a timestamp batch above the node's measured limit", () => {
  // The node answers 429 to a JSON-RPC batch of 101. A config that asked for more would fail on
  // every pass, at the point where it is hardest to attribute.
  assert.throws(() => loadConfig(write({ ...valid, timestampBatchSize: 500 }), {}), /100 or less/)
  assert.equal(loadConfig(write({ ...valid, timestampBatchSize: 100 }), {}).timestampBatchSize, 100)
})

test("the RPC URL comes from the environment when it is set there", () => {
  const config = loadConfig(write(valid), { RPC_URL: "https://other.example/rpc" })
  assert.equal(config.rpcUrl, "https://other.example/rpc")
})

test("it refuses an RPC URL that is not http", () => {
  assert.throws(() => loadConfig(write({ ...valid, rpcUrl: "wss://feed.example" }), {}), /http/)
})

test("it refuses a missing file rather than starting on defaults", () => {
  assert.throws(() => loadConfig(join(directory, "absent.json"), {}), /cannot read/)
})

test("there is nowhere in the config for a private key", () => {
  // The indexer reads the chain and serves reads. It has no transaction to sign, and the absence
  // of a key is a property worth pinning: a compromised index must cost an incident report and
  // no funds. This fails the moment somebody adds one.
  const config = loadConfig(write({ ...valid, privateKey: "0x" + "11".repeat(32) }), {
    PRIVATE_KEY: "0x" + "22".repeat(32)
  })
  assert.equal(
    Object.keys(config).some(key => /key|secret|mnemonic|signer/i.test(key)),
    false
  )
  // Config carries bigints, which JSON.stringify refuses outright; the replacer is here so the
  // assertion is about secrets rather than about serialisation.
  const flat = JSON.stringify(config, (_key, value) => (typeof value === "bigint" ? value.toString() : value))
  assert.equal(flat.includes("11".repeat(32)), false)
  assert.equal(flat.includes("22".repeat(32)), false)
})
