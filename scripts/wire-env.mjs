import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..")

const chainArg = process.argv[2] ?? "31337"
const chains = {
  "31337": { id: "31337", name: "local", rpc: "http://127.0.0.1:8545" },
  local: { id: "31337", name: "local", rpc: "http://127.0.0.1:8545" },
  "46630": { id: "46630", name: "testnet", rpc: "https://rpc.testnet.chain.robinhood.com" },
  testnet: { id: "46630", name: "testnet", rpc: "https://rpc.testnet.chain.robinhood.com" },
  "4663": { id: "4663", name: "mainnet", rpc: "https://rpc.mainnet.chain.robinhood.com" },
  mainnet: { id: "4663", name: "mainnet", rpc: "https://rpc.mainnet.chain.robinhood.com" }
}
const chain = chains[chainArg]
if (!chain) {
  console.error(`unknown chain "${chainArg}"; use local, testnet, or mainnet`)
  process.exit(1)
}

const broadcastPath = join(repoRoot, "contracts", "broadcast", "Deploy.s.sol", chain.id, "run-latest.json")
const broadcast = JSON.parse(readFileSync(broadcastPath, "utf8"))

const creates = broadcast.transactions.filter(tx => tx.transactionType === "CREATE")
const bySymbol = {}
let pool
let registry
let desk
for (const tx of creates) {
  if (tx.contractName === "MockERC20") {
    bySymbol[tx.arguments[1]] = tx.contractAddress
  } else if (tx.contractName === "SafixPool") {
    pool = tx.contractAddress
  } else if (tx.contractName === "PassportRegistry") {
    registry = tx.contractAddress
  } else if (tx.contractName === "PartnershipDesk") {
    desk = tx.contractAddress
  }
}

const stable = bySymbol.tUSDG
if (!pool || !stable) {
  console.error("broadcast is missing the pool or the stable token; run the deploy script first")
  process.exit(1)
}

const deployBlock = Math.min(
  ...broadcast.receipts.map(receipt => Number.parseInt(receipt.blockNumber, 16))
)

const appDir = process.env.APP_DIR ?? resolve(repoRoot, "..", "safix-app")
const envPath = join(appDir, ".env.local")

// Only these come from the deployment. Everything else already in .env.local belongs to whoever
// runs the app -- the WalletConnect project, a dedicated RPC, error reporting, analytics -- and
// rewriting the file from scratch would silently throw it away.
const derived = {
  NEXT_PUBLIC_CHAIN: chain.name,
  NEXT_PUBLIC_POOL_ADDRESS: pool,
  NEXT_PUBLIC_USDG_ADDRESS: stable,
  NEXT_PUBLIC_REGISTRY_ADDRESS: registry ?? "",
  NEXT_PUBLIC_DESK_ADDRESS: desk ?? "",
  NEXT_PUBLIC_ASSET_TBILL: bySymbol.tBILL ?? "",
  NEXT_PUBLIC_ASSET_BNVDA: bySymbol.bNVDA ?? "",
  NEXT_PUBLIC_ASSET_TGOLD: bySymbol.tGOLD ?? "",
  // Deliberately blank unless the operator sets it. An unset index means the app reads the chain,
  // which is the shipping default until one is actually running somewhere.
  NEXT_PUBLIC_INDEXER_URL: process.env.INDEXER_URL ?? ""
}

let existingLines = []
try {
  existingLines = readFileSync(envPath, "utf8").split("\n")
} catch {
  // No file yet: the derived keys below become the whole of it.
}

const written = new Set()
const preserved = []
const envLines = []
for (const line of existingLines) {
  const key = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(line)?.[1]
  if (key === undefined) {
    envLines.push(line)
  } else if (key in derived) {
    envLines.push(`${key}=${derived[key]}`)
    written.add(key)
  } else {
    envLines.push(line)
    preserved.push(key)
  }
}
// Trailing blank lines would push new keys past the end of the file.
while (envLines.length > 0 && envLines[envLines.length - 1].trim() === "") envLines.pop()
for (const [key, value] of Object.entries(derived)) {
  if (!written.has(key)) envLines.push(`${key}=${value}`)
}
// The app treats an unset override as "use the chain's default RPC".
if (!existingLines.some(line => line.startsWith("NEXT_PUBLIC_RPC_OVERRIDE="))) {
  envLines.push("NEXT_PUBLIC_RPC_OVERRIDE=")
}
envLines.push("")

writeFileSync(envPath, envLines.join("\n"))

const keeperConfig = {
  rpcUrl: chain.rpc,
  poolAddress: pool,
  deployBlock,
  intervalMs: 15000,
  prices: {},
  // Blank unless the operator points it at one; the keeper then scans the logs itself.
  indexer: { url: process.env.INDEXER_URL ?? null }
}
const keeperPath = join(repoRoot, "keeper", "config.json")
mkdirSync(dirname(keeperPath), { recursive: true })
writeFileSync(keeperPath, `${JSON.stringify(keeperConfig, null, 2)}\n`)

// The index carries the desk and the registry as well as the pool, because a wallet's history
// spans all three and it is the only service that reads more than one contract.
const indexerConfig = {
  rpcUrl: chain.rpc,
  poolAddress: pool,
  deskAddress: desk ?? null,
  registryAddress: registry ?? null,
  deployBlock,
  intervalMs: 20000,
  databasePath: "./safix-index.db",
  port: 8080
}
const indexerPath = join(repoRoot, "indexer", "config.json")
mkdirSync(dirname(indexerPath), { recursive: true })
writeFileSync(indexerPath, `${JSON.stringify(indexerConfig, null, 2)}\n`)

console.log(`chain ${chain.name} (${chain.id})`)
console.log(`pool ${pool}`)
console.log(`wrote ${envPath}`)
if (preserved.length > 0) console.log(`kept ${preserved.length} existing key(s): ${preserved.join(", ")}`)
console.log(`wrote ${keeperPath}`)
console.log(`wrote ${indexerPath}`)
