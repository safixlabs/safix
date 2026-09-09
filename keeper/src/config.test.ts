import assert from "node:assert/strict"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { liquidationsAffordable } from "./alerts.ts"
import { loadConfig, loadPrivateKey } from "./config.ts"

const dir = mkdtempSync(join(tmpdir(), "keeper-"))
const write = (name: string, body: unknown) => {
  const path = join(dir, name)
  writeFileSync(path, JSON.stringify(body))
  return path
}

const valid = {
  rpcUrl: "https://rpc.testnet.chain.robinhood.com",
  poolAddress: "0x501C6338ba46144662eA530c5baF9d5218CD079a",
  deployBlock: 100,
  intervalMs: 15000
}

test("a valid config loads with defaults filled in", () => {
  const config = loadConfig(write("ok.json", valid), {} as NodeJS.ProcessEnv)
  assert.equal(config.intervalMs, 15000)
  assert.equal(config.deployBlock, 100n)
  assert.equal(config.alerts.stuckScans, 3)
  assert.equal(config.instanceId, "keeper")
  assert.ok(config.gas.criticalLiquidations < config.gas.warnLiquidations)
})

test("a keeper refuses to start on a config it cannot trust", () => {
  // Booting with a half-valid config is worse than not booting: it looks like it is watching.
  assert.throws(() => loadConfig(write("a.json", { ...valid, rpcUrl: "not-a-url" }), {} as NodeJS.ProcessEnv), /rpcUrl/)
  assert.throws(() => loadConfig(write("b.json", { ...valid, poolAddress: "0x1234" }), {} as NodeJS.ProcessEnv), /poolAddress/)
  assert.throws(
    () => loadConfig(write("c.json", { ...valid, poolAddress: "0x0000000000000000000000000000000000000000" }), {} as NodeJS.ProcessEnv),
    /zero address/
  )
  assert.throws(() => loadConfig(write("d.json", { ...valid, intervalMs: 0 }), {} as NodeJS.ProcessEnv), /intervalMs/)
  assert.throws(() => loadConfig(write("e.json", { ...valid, prices: { notAnAddress: 1 } }), {} as NodeJS.ProcessEnv), /non-address/)
  assert.throws(() => loadConfig(join(dir, "missing.json"), {} as NodeJS.ProcessEnv), /cannot read/)
})

test("the gas warning has to fire before the critical one", () => {
  assert.throws(
    () => loadConfig(write("f.json", { ...valid, gas: { warnLiquidations: 10, criticalLiquidations: 20 } }), {} as NodeJS.ProcessEnv),
    /must be below/
  )
})

test("the private key comes from the environment and nowhere else", () => {
  const key = "0x" + "11".repeat(32)
  assert.equal(loadPrivateKey({ PRIVATE_KEY: key } as NodeJS.ProcessEnv), key)
  assert.throws(() => loadPrivateKey({} as NodeJS.ProcessEnv), /required/)
  assert.throws(() => loadPrivateKey({ PRIVATE_KEY: "0xabc" } as NodeJS.ProcessEnv), /32-byte/)

  // A key placed in the config file is ignored rather than honoured.
  const config = loadConfig(write("g.json", { ...valid, privateKey: key }), {} as NodeJS.ProcessEnv)
  assert.equal((config as Record<string, unknown>).privateKey, undefined)
})

test("the webhook is read from the environment, not the config file", () => {
  const fromFile = loadConfig(write("h.json", { ...valid, alerts: { webhookUrl: "https://leaked" } }), {} as NodeJS.ProcessEnv)
  assert.equal(fromFile.alerts.webhookUrl, null)
  const fromEnv = loadConfig(write("i.json", valid), { ALERT_WEBHOOK_URL: "https://hook" } as NodeJS.ProcessEnv)
  assert.equal(fromEnv.alerts.webhookUrl, "https://hook")
})

test("a balance is reported as liquidations affordable, not as wei", () => {
  // 0.01 ETH at 0.02 gwei and 150k gas per liquidation.
  const balance = 10n ** 16n
  const gasPrice = 20_000_000n
  assert.equal(liquidationsAffordable(balance, gasPrice, 150_000n), 3333)
  assert.equal(liquidationsAffordable(0n, gasPrice, 150_000n), 0)
})

test("the indexer is optional, and absent means the keeper scans the logs itself", () => {
  const config = loadConfig(write("no-index.json", { ...valid, indexer: { url: null } }), {} as NodeJS.ProcessEnv)
  assert.equal(config.indexerUrl, null)
  assert.ok(config.indexerTimeoutMs > 0)
  assert.ok(config.indexerMaxLagBlocks > 0)
})

test("the indexer URL can come from the environment, and must be http", () => {
  assert.equal(
    loadConfig(write("env-index.json", valid), { INDEXER_URL: "http://index:8080" } as NodeJS.ProcessEnv).indexerUrl,
    "http://index:8080"
  )
  assert.throws(
    () => loadConfig(write("bad-index.json", { ...valid, indexer: { url: "index:8080" } }), {} as NodeJS.ProcessEnv),
    /http/
  )
})
