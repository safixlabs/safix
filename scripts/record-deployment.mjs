// Records a broadcast as deployments/<network>.json: every deployed address, the block the
// deployment started at, and the commit the bytecode was built from.
//
// Usage: node scripts/record-deployment.mjs <local|testnet|mainnet> [--script Deploy.s.sol] [--worktree <path>]
//
// Everything is read back out of Foundry's broadcast file and the git worktree; nothing is typed in.
//
// --worktree names the checkout the broadcast ran from, when that is not this one: a deployment is
// made from a clean checkout of a tagged commit, and recorded from the branch that carries the record.
// The broadcast, the commit and the dirtiness are all read from there; the record is written here.
//
// On testnet and mainnet the record is refused unless the deployed source is clean, the commit carries
// a tag, and the commit is on main (#34). A redeploy keeps the deployment it replaces under
// `superseded`, newest first, so an integrator holding an old address can find out that it moved.

import { execFileSync } from "node:child_process"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..")

const networks = {
  local: { id: "31337", name: "local", explorer: null },
  31337: { id: "31337", name: "local", explorer: null },
  testnet: { id: "46630", name: "testnet", explorer: "https://explorer.testnet.chain.robinhood.com" },
  46630: { id: "46630", name: "testnet", explorer: "https://explorer.testnet.chain.robinhood.com" },
  mainnet: { id: "4663", name: "mainnet", explorer: "https://robinhoodchain.blockscout.com" },
  4663: { id: "4663", name: "mainnet", explorer: "https://robinhoodchain.blockscout.com" }
}

const args = process.argv.slice(2)
const flagValues = new Set(
  ["--script", "--worktree"].map(flag => args.indexOf(flag)).filter(index => index !== -1).map(index => index + 1)
)
const networkArg = args.find((arg, index) => !arg.startsWith("--") && !flagValues.has(index)) ?? "testnet"
const scriptFlagIndex = args.indexOf("--script")
const scriptName = scriptFlagIndex === -1 ? "Deploy.s.sol" : args[scriptFlagIndex + 1]
const worktreeFlagIndex = args.indexOf("--worktree")
const sourceRoot = worktreeFlagIndex === -1 ? repoRoot : resolve(args[worktreeFlagIndex + 1])

const network = networks[networkArg]
if (!network) {
  console.error(`unknown network "${networkArg}"; use local, testnet, or mainnet`)
  process.exit(1)
}

const broadcastPath = join(sourceRoot, "contracts", "broadcast", scriptName, network.id, "run-latest.json")

let broadcast
try {
  broadcast = JSON.parse(readFileSync(broadcastPath, "utf8"))
} catch (error) {
  console.error(`cannot read ${broadcastPath}`)
  console.error(`run the ${scriptName} broadcast against ${network.name} first`)
  console.error(error.message)
  process.exit(1)
}

const git = command => execFileSync("git", command, { cwd: sourceRoot, encoding: "utf8" }).trim()

const commit = git(["rev-parse", "HEAD"])

// Only the paths that decide the deployed bytecode make the recorded commit untrustworthy: the
// contracts themselves, their dependencies, the compiler settings, and the script that chose what
// to deploy. Unrelated edits elsewhere in the worktree are reported but do not invalidate the hash.
const bytecodePaths = [
  "contracts/src",
  "contracts/lib",
  "contracts/foundry.toml",
  `contracts/script/${scriptName}`
]
const sourceDirty = git(["status", "--porcelain", "--", ...bytecodePaths]).length > 0
const worktreeDirty = git(["status", "--porcelain"]).length > 0

// The tag and main are what make a deployment reproducible by someone else: a tag names the commit
// in a way that survives a force-push to a branch, and main is where every reviewed change lands.
const tags = git(["tag", "--points-at", commit]).split("\n").filter(Boolean)
const mainRef = ["origin/main", "main"].find(ref => {
  try {
    git(["rev-parse", "--verify", "--quiet", ref])
    return true
  } catch {
    return false
  }
})
let onMain = false
if (mainRef) {
  try {
    git(["merge-base", "--is-ancestor", commit, mainRef])
    onMain = true
  } catch {
    onMain = false
  }
}

if (network.name !== "local") {
  const refusals = []
  if (sourceDirty) refusals.push("the deployed source has uncommitted edits")
  if (tags.length === 0) refusals.push(`commit ${commit.slice(0, 12)} carries no tag`)
  if (!onMain) refusals.push(`commit ${commit.slice(0, 12)} is not on ${mainRef ?? "main"}`)
  if (refusals.length > 0) {
    console.error(`refusing to record a ${network.name} deployment:`)
    for (const refusal of refusals) console.error(`  - ${refusal}`)
    console.error("deploy from a clean checkout of a tagged commit on main, then record with --worktree")
    process.exit(1)
  }
}

const receiptByHash = new Map(broadcast.receipts.map(receipt => [receipt.transactionHash, receipt]))
const blockOf = receipt => (receipt ? Number.parseInt(receipt.blockNumber, 16) : null)

const contracts = {}
for (const transaction of broadcast.transactions) {
  if (transaction.transactionType !== "CREATE") continue
  const receipt = receiptByHash.get(transaction.hash)
  const entry = {
    address: transaction.contractAddress,
    transactionHash: transaction.hash,
    block: blockOf(receipt)
  }
  // Several MockERC20 instances share a contract name; key them by their token symbol.
  const symbol = transaction.contractName === "MockERC20" ? transaction.arguments?.[1] : null
  const key = symbol ? symbol.replaceAll('"', "") : transaction.contractName
  if (contracts[key]) {
    console.error(`two deployments share the key "${key}"; cannot record unambiguously`)
    process.exit(1)
  }
  contracts[key] = entry
}

if (Object.keys(contracts).length === 0) {
  console.error("the broadcast contains no CREATE transactions")
  process.exit(1)
}

const blocks = broadcast.receipts.map(blockOf).filter(block => block !== null)
const deployBlock = Math.min(...blocks)

const failed = broadcast.receipts.filter(receipt => receipt.status !== "0x1")
if (failed.length > 0) {
  console.error(`${failed.length} transaction(s) in the broadcast did not succeed; refusing to record`)
  for (const receipt of failed) console.error(`  ${receipt.transactionHash} status ${receipt.status}`)
  process.exit(1)
}

// Foundry stamps the broadcast with the short commit it ran from. If that no longer matches the
// worktree, the addresses below were built from different source than HEAD describes.
const broadcastCommit = broadcast.commit ?? null
const commitMatchesBroadcast = broadcastCommit === null || commit.startsWith(broadcastCommit)

const outputDir = join(repoRoot, "deployments")
const outputPath = join(outputDir, `${network.name}.json`)

// The deployment this one replaces, if any. Re-recording the same broadcast leaves the history alone.
let previous = null
try {
  previous = JSON.parse(readFileSync(outputPath, "utf8"))
} catch {
  previous = null
}
const addressesOf = entry =>
  Object.fromEntries(Object.entries(entry?.contracts ?? {}).map(([name, value]) => [name, value.address]))
const sameDeployment =
  previous !== null && JSON.stringify(addressesOf(previous)) === JSON.stringify(addressesOf({ contracts }))
let superseded = previous?.superseded ?? []
if (previous !== null && !sameDeployment) {
  superseded = [
    {
      commit: previous.commit,
      tag: previous.tag ?? null,
      deployBlock: previous.deployBlock,
      deployedAt: previous.deployedAt,
      supersededAt: new Date(broadcast.timestamp).toISOString(),
      supersededByCommit: commit,
      contracts: addressesOf(previous)
    },
    ...superseded
  ]
}

const record = {
  network: network.name,
  chainId: Number(network.id),
  commit,
  tag: tags[0] ?? null,
  onMain,
  sourceIsDirty: sourceDirty,
  worktreeIsDirty: worktreeDirty,
  script: scriptName,
  deployBlock,
  deployedAt: new Date(broadcast.timestamp).toISOString(),
  explorer: network.explorer,
  contracts,
  superseded
}

mkdirSync(outputDir, { recursive: true })
writeFileSync(outputPath, `${JSON.stringify(record, null, 2)}\n`)

console.log(`network ${network.name} (${network.id})`)
console.log(`commit ${commit}${sourceDirty ? " (deployed source is dirty)" : ""}`)
console.log(`tag ${tags[0] ?? "(none)"} · on ${mainRef ?? "main"}: ${onMain ? "yes" : "no"}`)
console.log(`deployed at ${record.deployedAt}`)
console.log(`deploy block ${deployBlock}`)
for (const [name, entry] of Object.entries(contracts)) {
  console.log(`  ${name.padEnd(18)} ${entry.address}`)
}
if (previous !== null && !sameDeployment) {
  console.log(`superseded: the ${previous.commit.slice(0, 12)} deployment at block ${previous.deployBlock}`)
}
console.log(`${superseded.length} superseded deployment(s) on record`)
console.log(`wrote ${outputPath}`)

if (sourceDirty) {
  console.warn("")
  console.warn("warning: the contracts, their dependencies, the compiler settings, or the deploy")
  console.warn("script had uncommitted edits, so the commit hash does not describe the deployed")
  console.warn("bytecode. Commit first, then redeploy, for a record that can be reproduced.")
}

if (!commitMatchesBroadcast) {
  console.warn("")
  console.warn(`warning: the broadcast ran from commit ${broadcastCommit}, but HEAD is now ${commit}.`)
  console.warn("The recorded commit does not describe the bytecode at these addresses.")
}
