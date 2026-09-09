import { readFileSync } from "node:fs"
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  getAddress,
  http,
  maxUint256,
  parseAbi
} from "viem"
import { privateKeyToAccount } from "viem/accounts"

const poolAbi = parseAbi([
  "function setPrice(address asset, uint256 priceUsd1e18)",
  "function currentPrice(address asset) view returns (uint256 price1e18, uint256 updatedAt)",
  "function isLiquidatable(address borrower, address asset) view returns (bool)",
  "function liquidate(address borrower, address asset, uint256 debtAmount)",
  "function positions(address borrower, address asset) view returns (uint256 collateral, uint256 debt, uint256 totalDrawn)",
  "event Drawn(address indexed borrower, address indexed asset, uint256 amount, uint256 fee)"
])

type KeeperConfig = {
  rpcUrl: string
  poolAddress: `0x${string}`
  deployBlock?: number
  intervalMs?: number
  prices?: Record<string, number>
}

const configPath = process.env.CONFIG ?? "./config.json"
const config: KeeperConfig = JSON.parse(readFileSync(configPath, "utf8"))

const privateKey = process.env.PRIVATE_KEY
if (!privateKey) {
  console.error("PRIVATE_KEY env var is required")
  process.exit(1)
}

const account = privateKeyToAccount(privateKey as `0x${string}`)
const transport = http(config.rpcUrl)
const publicClient = createPublicClient({ transport })
const pool = getAddress(config.poolAddress)

const toPrice1e18 = (value: number) => BigInt(Math.round(value * 1e8)) * 10n ** 10n

const log = (message: string) => {
  console.log(`[${new Date().toISOString()}] ${message}`)
}

/// Pulls the revert reason out of a viem error, which carries it a few lines into a long message.
/// Without this the log says a call reverted but never says why, which is the only useful part.
const reason = (error: unknown) => {
  const text = error instanceof Error ? error.message : String(error)
  const reverted = text.match(/reverted with the following reason:\s*\n?\s*(.+)/)
  return (reverted?.[1] ?? text.split("\n")[0]).trim()
}

async function walletClient() {
  const chainId = await publicClient.getChainId()
  const chain = defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [config.rpcUrl] } }
  })
  return createWalletClient({ account, chain, transport })
}

async function pushPrices() {
  const entries = Object.entries(config.prices ?? {})
  if (entries.length === 0) return
  const wallet = await walletClient()
  for (const [assetRaw, price] of entries) {
    const asset = getAddress(assetRaw)
    const target = toPrice1e18(price)
    try {
      const [current] = await publicClient.readContract({
        abi: poolAbi,
        address: pool,
        functionName: "currentPrice",
        args: [asset]
      })
      if (current === target) continue
      const hash = await wallet.writeContract({
        abi: poolAbi,
        address: pool,
        functionName: "setPrice",
        args: [asset, target]
      })
      await publicClient.waitForTransactionReceipt({ hash })
      log(`price set ${asset} -> ${price} (${hash})`)
    } catch (error) {
      // The pool refuses a price outside the asset's band or one that moves too far in a single
      // update. That is the guard doing its job, and it says nothing about the other assets, so
      // the rest of the loop continues.
      log(`price push failed for ${asset}: ${reason(error)}`)
    }
  }
}

async function discoverPositions() {
  const logs = await publicClient.getLogs({
    address: pool,
    event: poolAbi.find(item => item.type === "event" && item.name === "Drawn"),
    fromBlock: BigInt(config.deployBlock ?? 0),
    toBlock: "latest"
  })
  const pairs = new Map<string, { borrower: `0x${string}`; asset: `0x${string}` }>()
  for (const entry of logs) {
    const borrower = entry.args.borrower
    const asset = entry.args.asset
    if (!borrower || !asset) continue
    pairs.set(`${borrower}:${asset}`, { borrower, asset })
  }
  return [...pairs.values()]
}

async function liquidateUnhealthy() {
  const pairs = await discoverPositions()
  log(`scanning ${pairs.length} position(s)`)
  const wallet = await walletClient()
  for (const { borrower, asset } of pairs) {
    try {
      // isLiquidatable answers false, rather than reverting, whenever the pool will not act on the
      // price: sequencer down or inside its grace window, stale, out of band, or a single-round
      // jump. One unusable feed therefore skips its own positions and no others.
      const liquidatable = await publicClient.readContract({
        abi: poolAbi,
        address: pool,
        functionName: "isLiquidatable",
        args: [borrower, asset]
      })
      if (!liquidatable) continue
      const [, debt] = await publicClient.readContract({
        abi: poolAbi,
        address: pool,
        functionName: "positions",
        args: [borrower, asset]
      })
      const hash = await wallet.writeContract({
        abi: poolAbi,
        address: pool,
        functionName: "liquidate",
        args: [borrower, asset, maxUint256]
      })
      await publicClient.waitForTransactionReceipt({ hash })
      log(`liquidated ${borrower} on ${asset}, debt ${debt} (${hash})`)
    } catch (error) {
      // Another keeper getting there first, or a position that stopped being liquidatable between
      // the read and the send, must not cost the remaining positions their scan.
      log(`liquidation failed for ${borrower} on ${asset}: ${reason(error)}`)
    }
  }
}

async function scanOnce() {
  // Liquidation is the pool's only defence and must not depend on the price push succeeding.
  // A pool-side rejection, a feed that will not answer or an RPC hiccup while pushing prices
  // is logged and stepped over, so the scan below still runs this pass.
  try {
    await pushPrices()
  } catch (error) {
    log(`price push failed: ${reason(error)}`)
  }
  await liquidateUnhealthy()
}

async function watch() {
  const interval = config.intervalMs ?? 15_000
  for (;;) {
    try {
      await scanOnce()
    } catch (error) {
      log(`scan failed: ${reason(error)}`)
    }
    await new Promise(resolve => setTimeout(resolve, interval))
  }
}

const mode = process.argv[2] ?? "scan"
if (mode === "watch") {
  log(`keeper watching ${pool} via ${config.rpcUrl}`)
  watch()
} else {
  scanOnce().then(() => log("scan complete"))
}
