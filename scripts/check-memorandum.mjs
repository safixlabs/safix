// Checks the claims in the information memorandum that this repository can
// settle for itself, so the document cannot quietly fall behind the code again.
//
//   node scripts/check-memorandum.mjs
//
// It does not check market figures or anything sourced outside the repository;
// those carry their own attribution in the document.

import { existsSync, readFileSync, readdirSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const problems = []

// --- what the code actually is ------------------------------------------------

const testDir = join(root, "contracts", "test")
if (!existsSync(testDir)) {
  problems.push("no contracts/test directory; this check has nothing to measure")
}
let tests = 0
let invariants = 0
if (existsSync(testDir)) {
  for (const file of readdirSync(testDir).filter(name => name.endsWith(".t.sol"))) {
    const text = readFileSync(join(testDir, file), "utf8")
    const found = [...text.matchAll(/function\s+(test|invariant)[A-Za-z0-9_]*\s*\(/g)]
    tests += found.length
    invariants += found.filter(match => match[1] === "invariant").length
  }
}

const deployments = join(root, "deployments")
const networks = existsSync(deployments)
  ? readdirSync(deployments)
      .filter(name => name.endsWith(".json"))
      .map(name => name.replace(/\.json$/, ""))
  : []

// --- what the document says ---------------------------------------------------

const documents = [
  join(root, "docs", "information-memorandum.md"),
  join(root, "docs", "information-memorandum.html")
]

for (const path of documents) {
  if (!existsSync(path)) {
    problems.push(`missing ${path}`)
    continue
  }
  const text = readFileSync(path, "utf8")
  const name = path.slice(root.length + 1)

  const claimed = text.match(/(\d+) tests green/)
  if (!claimed) {
    problems.push(`${name} no longer states a test count in the form "N tests green"`)
  } else if (Number(claimed[1]) !== tests) {
    problems.push(`${name} claims ${claimed[1]} tests, the suite has ${tests}`)
  }

  const claimedInvariants = text.match(/(\w+) stateful invariants/)
  const words = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8 }
  if (claimedInvariants) {
    const value = words[claimedInvariants[1]] ?? Number(claimedInvariants[1])
    if (value !== invariants) {
      problems.push(`${name} claims ${claimedInvariants[1]} stateful invariants, the suite has ${invariants}`)
    }
  }

  // A deployment that exists has to be reflected, and one that does not must not be claimed.
  const saysTestnet = /deployed to Robinhood Chain Testnet/i.test(text)
  if (networks.includes("testnet") && !saysTestnet) {
    problems.push(`${name} does not mention the testnet deployment, and deployments/testnet.json exists`)
  }
  if (!networks.includes("testnet") && saysTestnet) {
    problems.push(`${name} claims a testnet deployment with no deployments/testnet.json to back it`)
  }
  if (/deploy to Robinhood Chain testnet/i.test(text) && networks.includes("testnet")) {
    problems.push(`${name} still lists deploying to testnet as upcoming work, but it has happened`)
  }
}

if (problems.length > 0) {
  console.error(`check-memorandum: ${problems.length} problem(s)`)
  for (const problem of problems) console.error(`  - ${problem}`)
  process.exit(1)
}

console.log(
  `check-memorandum: ok, ${tests} tests (${invariants} invariants), deployments: ${
    networks.length > 0 ? networks.join(", ") : "none"
  }`
)
