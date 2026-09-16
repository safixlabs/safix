import { parseAbi, type PublicClient } from "viem"

/// Everything the monitor reads, in one pass. All of it comes from chain state: there is no
/// database, and nothing here is derived from a record the monitor keeps itself. Restarting it
/// loses no information about the protocol, only about how long something has been wrong.

export const poolAbi = parseAbi([
  "function totalDeposits() view returns (uint256)",
  "function totalDebt() view returns (uint256)",
  "function availableLiquidity() view returns (uint256)",
  "function drawableLiquidity() view returns (uint256)",
  "function protocolFees() view returns (uint256)",
  "function reserve() view returns (uint256)",
  "function badDebt() view returns (uint256)",
  "function pausedActions() view returns (uint8)",
  "function assetCount() view returns (uint256)",
  "function assetList(uint256) view returns (address)",
  "function assetConfig(address) view returns (bool enabled, uint16 maxLtvBps, uint16 liqThresholdBps, uint256 priceUsd1e18, uint256 debtCap, uint256 collateralCap)",
  "function priceStatus(address) view returns (uint8 status, uint256 price1e18, uint256 updatedAt)",
  "function priceGuards(address) view returns (uint64 maxPriceAge, uint16 maxDeviationBps, uint256 minPrice1e18, uint256 maxPrice1e18)",
  "function assetDebt(address) view returns (uint256)",
  "function assetCollateral(address) view returns (uint256)",
  "function positions(address,address) view returns (uint256 collateral, uint256 debt, uint256 principal)",
  "function isLiquidatable(address,address) view returns (bool)",
  "event Drawn(address indexed borrower, address indexed asset, uint256 amount, uint256 fee)",
  "event Deposited(address indexed provider, uint256 amount)",
  "event Withdrawn(address indexed provider, uint256 amount)",
  "event Liquidated(address indexed borrower, address indexed asset, address indexed caller, uint256 debtOffset, uint256 collateralSeized)"
])

/// Names for the pool's PriceStatus enum, so an alert says "Stale" rather than "5".
export const PRICE_STATUS = [
  "Ok",
  "AssetDisabled",
  "SequencerDown",
  "SequencerGracePeriod",
  "FeedUnavailable",
  "Stale",
  "BelowBand",
  "AboveBand",
  "DeviationTooLarge"
] as const

export type AssetMetrics = {
  address: `0x${string}`
  enabled: boolean
  maxLtvBps: number
  liqThresholdBps: number
  price1e18: bigint
  priceUpdatedAt: bigint
  /// Seconds since the price was last updated, which is the number a heartbeat is judged against.
  oracleAgeSeconds: number
  /// The asset's own age limit, or null when it has no guard configured.
  maxPriceAge: number | null
  priceStatus: string
  debt: bigint
  collateral: bigint
  debtCap: bigint
  collateralCap: bigint
}

export type PositionMetrics = {
  borrower: `0x${string}`
  asset: `0x${string}`
  collateral: bigint
  debt: bigint
  collateralValue: bigint
  /// Ratio of collateral value to the value at which this position becomes liquidatable. Below 1
  /// it already is. Expressed in basis points so it stays an integer.
  healthBps: number
  liquidatable: boolean
}

export type Snapshot = {
  blockNumber: bigint
  timestamp: number
  poolSize: bigint
  totalDebt: bigint
  availableLiquidity: bigint
  drawableLiquidity: bigint
  protocolFees: bigint
  reserve: bigint
  badDebt: bigint
  pausedActions: number
  /// Debt over pool size, in basis points. The number an operator watches.
  utilisationBps: number
  assets: AssetMetrics[]
  positions: PositionMetrics[]
}

const BPS = 10_000n

/// Discovers every borrower and asset pair that has ever drawn, in chunks the RPC will accept.
export async function discoverPositions(
  client: PublicClient,
  pool: `0x${string}`,
  fromBlock: bigint,
  chunk: bigint
): Promise<{ borrower: `0x${string}`; asset: `0x${string}` }[]> {
  const latest = await client.getBlockNumber()
  const pairs = new Map<string, { borrower: `0x${string}`; asset: `0x${string}` }>()
  const event = poolAbi.find(item => item.type === "event" && item.name === "Drawn")

  for (let from = fromBlock; from <= latest; from += chunk) {
    const to = from + chunk - 1n
    const logs = await client.getLogs({
      address: pool,
      event: event as never,
      fromBlock: from,
      toBlock: to > latest ? latest : to
    })
    for (const entry of logs) {
      const args = (entry as { args?: { borrower?: `0x${string}`; asset?: `0x${string}` } }).args
      if (!args?.borrower || !args?.asset) continue
      pairs.set(`${args.borrower}:${args.asset}`, { borrower: args.borrower, asset: args.asset })
    }
  }
  return [...pairs.values()]
}

/// Reads the whole protocol in one pass. Every number here has a contract behind it, so the
/// dashboard and the alerts cannot disagree with the chain: they are reading the same call.
export async function readSnapshot(
  client: PublicClient,
  pool: `0x${string}`,
  pairs: { borrower: `0x${string}`; asset: `0x${string}` }[]
): Promise<Snapshot> {
  const read = <T>(functionName: string, args: readonly unknown[] = []) =>
    client.readContract({ abi: poolAbi, address: pool, functionName, args: args as never }) as Promise<T>

  const [block, poolSize, totalDebt, available, drawable, fees, reserve, badDebt, paused, assetCount] =
    await Promise.all([
      client.getBlock(),
      read<bigint>("totalDeposits"),
      read<bigint>("totalDebt"),
      read<bigint>("availableLiquidity"),
      read<bigint>("drawableLiquidity"),
      read<bigint>("protocolFees"),
      read<bigint>("reserve"),
      read<bigint>("badDebt"),
      read<number>("pausedActions"),
      read<bigint>("assetCount")
    ])

  const now = Number(block.timestamp)

  const assetAddresses = await Promise.all(
    Array.from({ length: Number(assetCount) }, (_, i) => read<`0x${string}`>("assetList", [BigInt(i)]))
  )

  const assets: AssetMetrics[] = await Promise.all(
    assetAddresses.map(async address => {
      const [config, status, guard, debt, collateral] = await Promise.all([
        read<[boolean, number, number, bigint, bigint, bigint]>("assetConfig", [address]),
        read<[number, bigint, bigint]>("priceStatus", [address]),
        read<[bigint, number, bigint, bigint]>("priceGuards", [address]),
        read<bigint>("assetDebt", [address]),
        read<bigint>("assetCollateral", [address])
      ])
      const [, statusPrice, statusUpdatedAt] = status
      // priceStatus zeroes the price when it refuses it, so fall back to the configured one for
      // display: an operator still wants to see what the feed last said.
      const price = statusPrice > 0n ? statusPrice : config[3]
      const updatedAt = statusUpdatedAt
      return {
        address,
        enabled: config[0],
        maxLtvBps: config[1],
        liqThresholdBps: config[2],
        price1e18: price,
        priceUpdatedAt: updatedAt,
        oracleAgeSeconds: updatedAt > 0n ? Math.max(0, now - Number(updatedAt)) : -1,
        maxPriceAge: guard[0] > 0n ? Number(guard[0]) : null,
        priceStatus: PRICE_STATUS[status[0]] ?? `unknown(${status[0]})`,
        debt,
        collateral,
        debtCap: config[4],
        collateralCap: config[5]
      }
    })
  )

  const byAsset = new Map(assets.map(asset => [asset.address.toLowerCase(), asset]))

  const positions: PositionMetrics[] = []
  for (const { borrower, asset } of pairs) {
    const [collateral, debt] = await read<[bigint, bigint, bigint]>("positions", [borrower, asset])
    if (debt === 0n) continue
    const meta = byAsset.get(asset.toLowerCase())
    if (!meta) continue

    const collateralValue = (collateral * meta.price1e18) / 10n ** 30n
    // The position becomes liquidatable when collateralValue * liqThreshold / BPS < debt, so the
    // value it would have to fall to is debt * BPS / liqThreshold.
    const liquidationValue = meta.liqThresholdBps > 0 ? (debt * BPS) / BigInt(meta.liqThresholdBps) : 0n
    const healthBps = liquidationValue > 0n ? Number((collateralValue * BPS) / liquidationValue) : 0
    const liquidatable = await read<boolean>("isLiquidatable", [borrower, asset])
    positions.push({ borrower, asset, collateral, debt, collateralValue, healthBps, liquidatable })
  }
  positions.sort((a, b) => a.healthBps - b.healthBps)

  return {
    blockNumber: block.number,
    timestamp: now,
    poolSize,
    totalDebt,
    availableLiquidity: available,
    drawableLiquidity: drawable,
    protocolFees: fees,
    reserve,
    badDebt,
    pausedActions: Number(paused),
    utilisationBps: poolSize > 0n ? Number((totalDebt * BPS) / poolSize) : 0,
    assets,
    positions
  }
}

/// Deposits and withdrawals in a recent window, so a large single movement can be noticed. Read
/// from events rather than kept in a table: the chain is the record.
export async function recentFlows(
  client: PublicClient,
  pool: `0x${string}`,
  blocks: bigint
): Promise<{ kind: "deposit" | "withdrawal"; who: `0x${string}`; amount: bigint; block: bigint }[]> {
  const latest = await client.getBlockNumber()
  const from = latest > blocks ? latest - blocks : 0n
  const flows: { kind: "deposit" | "withdrawal"; who: `0x${string}`; amount: bigint; block: bigint }[] = []

  for (const [name, kind] of [
    ["Deposited", "deposit"],
    ["Withdrawn", "withdrawal"]
  ] as const) {
    const event = poolAbi.find(item => item.type === "event" && item.name === name)
    const logs = await client.getLogs({ address: pool, event: event as never, fromBlock: from, toBlock: latest })
    for (const entry of logs) {
      const args = (entry as { args?: { provider?: `0x${string}`; amount?: bigint } }).args
      if (!args?.provider || args.amount === undefined) continue
      flows.push({ kind, who: args.provider, amount: args.amount, block: entry.blockNumber ?? 0n })
    }
  }
  return flows.sort((a, b) => Number(a.block - b.block))
}
