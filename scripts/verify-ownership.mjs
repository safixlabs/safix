// Reads the privileged roles off the chain and reports whether any of them is still an EOA.
//
// Usage: node scripts/verify-ownership.mjs <local|testnet|mainnet>
//
// Addresses come from deployments/<network>.json. Nothing is passed in, so this checks the
// deployment that was actually recorded rather than one someone believes is live.

import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..")

const rpcs = {
  local: "http://127.0.0.1:8545",
  testnet: "https://rpc.testnet.chain.robinhood.com",
  mainnet: "https://rpc.mainnet.chain.robinhood.com"
}

const network = process.argv[2] ?? "testnet"
const rpc = rpcs[network]
if (!rpc) {
  console.error(`unknown network "${network}"; use local, testnet, or mainnet`)
  process.exit(1)
}

const deployment = JSON.parse(readFileSync(join(repoRoot, "deployments", `${network}.json`), "utf8"))
const at = name => deployment.contracts[name]?.address

const cast = (...args) => execFileSync("cast", [...args, "--rpc-url", rpc], { encoding: "utf8" }).trim()
const call = (address, signature, ...args) => cast("call", address, signature, ...args).split(/\s+/)[0]

/// An address with no code is an externally owned account: one key, one signature, no threshold.
const isEoa = address => {
  if (!address || /^0x0+$/.test(address)) return false
  return cast("code", address) === "0x"
}

const pool = at("SafixPool")
const registry = at("PassportRegistry")
const desk = at("PartnershipDesk")
const timelock = at("SafixTimelock")

if (!pool || !registry || !desk) {
  console.error("deployment record is missing one of the three contracts")
  process.exit(1)
}

const roles = [
  { role: "SafixPool.owner", address: call(pool, "owner()(address)"), mustNotBeEoa: true },
  { role: "SafixPool.timelock", address: call(pool, "timelock()(address)"), mustNotBeEoa: true },
  { role: "PassportRegistry.owner", address: call(registry, "owner()(address)"), mustNotBeEoa: true },
  { role: "PartnershipDesk.owner", address: call(desk, "owner()(address)"), mustNotBeEoa: true },
  { role: "PartnershipDesk.timelock", address: call(desk, "timelock()(address)"), mustNotBeEoa: true },
  // The guardian is an EOA on purpose: the brake has to be reachable in one signature, and it can
  // only ever stop the protocol, never change a parameter or move a token.
  { role: "SafixPool.guardian", address: call(pool, "guardian()(address)"), mustNotBeEoa: false },
  // Likewise the price updater, which posts prices at the feed's own cadence and nothing else.
  { role: "SafixPool.priceUpdater", address: call(pool, "priceUpdater()(address)"), mustNotBeEoa: false }
]

if (timelock) {
  roles.splice(2, 0, { role: "SafixTimelock.admin", address: call(timelock, "admin()(address)"), mustNotBeEoa: true })
}

console.log(`network ${network}, commit ${deployment.commit.slice(0, 12)}\n`)
console.log(`${"ROLE".padEnd(28)} ${"ADDRESS".padEnd(44)} KIND`)

let failures = 0
for (const entry of roles) {
  const unset = /^0x0+$/.test(entry.address)
  const eoa = isEoa(entry.address)
  const kind = unset ? "unset" : eoa ? "EOA" : "contract"
  const bad = entry.mustNotBeEoa && (eoa || unset)
  if (bad) failures += 1
  console.log(`${entry.role.padEnd(28)} ${entry.address.padEnd(44)} ${kind}${bad ? "   <- MUST NOT BE" : ""}`)
}

if (timelock) {
  console.log(`\ntimelock delay ${call(timelock, "delay()(uint256)")}s, floor ${call(timelock, "MIN_DELAY()(uint256)")}s`)
}

console.log("")
if (failures > 0) {
  console.error(`${failures} privileged role(s) still held by an EOA or unset`)
  process.exit(1)
}
console.log("no privileged role is held by an EOA")
console.log("the guardian and the price updater are EOAs by design: neither can change a parameter")
