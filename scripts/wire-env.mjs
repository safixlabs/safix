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

const usdc = bySymbol.tUSDG
if (!pool || !usdc) {
  console.error("broadcast is missing the pool or the stable token; run the deploy script first")
  process.exit(1)
}

const deployBlock = Math.min(
  ...broadcast.receipts.map(receipt => Number.parseInt(receipt.blockNumber, 16))
)

const appDir = process.env.APP_DIR ?? resolve(repoRoot, "..", "safix-app")
const envLines = [
  `NEXT_PUBLIC_CHAIN=${chain.name}`,
  "NEXT_PUBLIC_RPC_OVERRIDE=",
  `NEXT_PUBLIC_POOL_ADDRESS=${pool}`,
  `NEXT_PUBLIC_USDC_ADDRESS=${usdc}`,
  `NEXT_PUBLIC_REGISTRY_ADDRESS=${registry ?? ""}`,
  `NEXT_PUBLIC_DESK_ADDRESS=${desk ?? ""}`,
  `NEXT_PUBLIC_ASSET_TBILL=${bySymbol.tBILL ?? ""}`,
  `NEXT_PUBLIC_ASSET_BNVDA=${bySymbol.bNVDA ?? ""}`,
  `NEXT_PUBLIC_ASSET_TGOLD=${bySymbol.tGOLD ?? ""}`,
  ""
]
const envPath = join(appDir, ".env.local")
writeFileSync(envPath, envLines.join("\n"))

const keeperConfig = {
  rpcUrl: chain.rpc,
  poolAddress: pool,
  deployBlock,
  intervalMs: 15000,
  prices: {}
}
const keeperPath = join(repoRoot, "keeper", "config.json")
mkdirSync(dirname(keeperPath), { recursive: true })
writeFileSync(keeperPath, `${JSON.stringify(keeperConfig, null, 2)}\n`)

console.log(`chain ${chain.name} (${chain.id})`)
console.log(`pool ${pool}`)
console.log(`wrote ${envPath}`)
console.log(`wrote ${keeperPath}`)
