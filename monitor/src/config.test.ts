import assert from "node:assert/strict"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { pct, usd } from "./alerts.ts"
import { loadConfig } from "./config.ts"

const dir = mkdtempSync(join(tmpdir(), "monitor-"))
const write = (name: string, body: unknown) => {
  const path = join(dir, name)
  writeFileSync(path, JSON.stringify(body))
  return path
}
const valid = {
  rpcUrl: "https://rpc.testnet.chain.robinhood.com",
  poolAddress: "0x501C6338ba46144662eA530c5baF9d5218CD079a",
  deployBlock: 100
}

test("a valid config loads with sensible defaults", () => {
  const config = loadConfig(write("ok.json", valid), {} as NodeJS.ProcessEnv)
  assert.equal(config.thresholds.utilisationBps, 8000)
  assert.equal(config.keeperAddress, null)
  assert.ok(config.thresholds.keeperSilentSeconds > config.thresholds.positionAtRiskSeconds)
})

test("the monitor refuses a config it cannot trust", () => {
  assert.throws(() => loadConfig(write("a.json", { ...valid, rpcUrl: "ftp://x" }), {} as NodeJS.ProcessEnv), /rpcUrl/)
  assert.throws(() => loadConfig(write("b.json", { ...valid, poolAddress: "0xdead" }), {} as NodeJS.ProcessEnv), /poolAddress/)
  assert.throws(
    () => loadConfig(write("c.json", { ...valid, keeperAddress: "not-an-address" }), {} as NodeJS.ProcessEnv),
    /keeperAddress/
  )
  assert.throws(
    () => loadConfig(write("d.json", { ...valid, thresholds: { utilisationBps: 20000 } }), {} as NodeJS.ProcessEnv),
    /cannot exceed/
  )
})

test("keeper_silent has to fire later than position_at_risk", () => {
  // Otherwise the two alerts arrive together and the second says nothing the first did not.
  assert.throws(
    () =>
      loadConfig(
        write("e.json", { ...valid, thresholds: { positionAtRiskSeconds: 900, keeperSilentSeconds: 300 } }),
        {} as NodeJS.ProcessEnv
      ),
    /must be greater than/
  )
})

test("the oracle warning has to arrive before the pool's own refusal", () => {
  // A ratio of 1 or more means the warning lands after draws are already blocked, which is late.
  assert.throws(
    () => loadConfig(write("f.json", { ...valid, thresholds: { oracleAgeWarningRatio: 1 } }), {} as NodeJS.ProcessEnv),
    /below 1/
  )
})

test("the webhook comes from the environment, never the config file", () => {
  const fromFile = loadConfig(write("g.json", { ...valid, alerts: { webhookUrl: "https://leaked" } }), {} as NodeJS.ProcessEnv)
  assert.equal(fromFile.alerts.webhookUrl, null)
  const fromEnv = loadConfig(write("h.json", valid), { ALERT_WEBHOOK_URL: "https://hook" } as NodeJS.ProcessEnv)
  assert.equal(fromEnv.alerts.webhookUrl, "https://hook")
})

test("the monitor holds no key at all", () => {
  // Not a validation rule but a property worth pinning: there is nowhere for one to be read from.
  const config = loadConfig(write("i.json", { ...valid, privateKey: "0x" + "11".repeat(32) }), {
    PRIVATE_KEY: "0x" + "22".repeat(32)
  } as NodeJS.ProcessEnv)
  const flat = JSON.stringify(config, (_, value) => (typeof value === "bigint" ? value.toString() : value))
  assert.equal(flat.includes("11".repeat(32)), false, "a key in the config file must not survive into the config")
  assert.equal(flat.includes("22".repeat(32)), false, "a key in the environment must not be picked up either")
})

test("amounts and ratios read the way a person reads them", () => {
  assert.equal(usd(244_975_000_000n), "244,975 USDG")
  assert.equal(pct(2_500), "25.0%")
})
