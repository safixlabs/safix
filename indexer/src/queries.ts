import type { EventRow, Store } from "./db.ts"

/// The questions the index exists to answer. Everything here is a read over the stored rows: no
/// contract call, no network. A query that needed the chain would be a query the chain could
/// already answer, and would not be worth an index.

const ONE_1E18 = 10n ** 18n

export type Serialised = Record<string, unknown>

const serialiseEvent = (row: EventRow): Serialised => ({
  block: Number(row.blockNumber),
  logIndex: row.logIndex,
  txHash: row.txHash,
  timestamp: row.timestamp,
  source: row.source,
  contract: row.address,
  name: row.name,
  asset: row.asset,
  args: row.args
})

/// A wallet's own history, newest first, across all three contracts.
///
/// Everything it has done as a liquidity provider, a borrower, a funder or an operator lands in
/// one list, because a person does not think of those as separate systems. `before` pages
/// backwards by block.
export function actionHistory(store: Store, address: string, limit: number, before: bigint | null) {
  const rows = store.eventsForActor(address.toLowerCase(), limit, before)
  return {
    address: address.toLowerCase(),
    count: rows.length,
    /// The block to pass as `before` for the next page. Absent when the list is exhausted.
    nextBefore: rows.length === limit ? Number(rows[rows.length - 1].blockNumber) : null,
    events: rows.map(serialiseEvent)
  }
}

/// A wallet's position in one asset, as the fold has it, alongside the events that produced it.
/// The caller can therefore check the number against its own history without a second request.
export function positionHistory(store: Store, borrower: string, asset: string, limit: number) {
  const current = store.position(borrower.toLowerCase(), asset.toLowerCase())
  const rows = store
    .eventsForActor(borrower.toLowerCase(), limit, null)
    .filter(row => row.asset === asset.toLowerCase())
  return {
    borrower: borrower.toLowerCase(),
    asset: asset.toLowerCase(),
    position: current
      ? {
          collateral: current.collateral.toString(),
          debt: current.debt.toString(),
          principal: current.principal.toString(),
          openedBlock: Number(current.openedBlock),
          lastBlock: Number(current.lastBlock)
        }
      : null,
    events: rows.map(serialiseEvent)
  }
}

/// Pool size, debt and utilisation at every block that moved either.
///
/// Utilisation is computed here rather than stored, so a change to what it means is a change in
/// one place. Basis points, to stay integral.
export function poolHistory(store: Store, limit: number) {
  const points = store.poolSeries(limit)
  return {
    count: points.length,
    points: points.map(point => {
      const deposits = BigInt(point.total_deposits)
      const debt = BigInt(point.total_debt)
      return {
        block: point.block_number,
        timestamp: point.timestamp,
        totalDeposits: point.total_deposits,
        totalDebt: point.total_debt,
        utilisationBps: deposits > 0n ? Number((debt * 10_000n) / deposits) : 0
      }
    })
  }
}

export type PricedLiquidation = {
  block: number
  timestamp: number | null
  txHash: string
  borrower: string | null
  asset: string | null
  caller: string
  debtCleared: string
  collateralSeized: string
  /// The asset's USD price at that block, scaled to 18 decimals, or null when no source covers
  /// the block. Never a guess: a liquidation with no price behind it says so.
  price1e18: string | null
  priceSource: "feed" | "manual" | null
  /// The feed the pool was reading at that block, when the price came from one.
  feed: string | null
  /// What the seized collateral was worth at that price, in stable units.
  collateralValue: string | null
  /// Present when the liquidation left the pool short. From BadDebtRealised in the same
  /// transaction, so this is the recorded loss rather than a derived one.
  shortfall: string | null
  fromReserve: string | null
  socialised: string | null
}

/// Liquidation history with the price the pool acted on.
///
/// The price is recovered from the feed's own AnswerUpdated logs, not from a historical call.
/// The node keeps state for about thirteen minutes, so by the time anyone asks about a
/// liquidation the state that priced it is gone; logs are not pruned, so the feed's log is the
/// last durable copy of its answer. `feedForAssetAt` picks the feed the pool was actually pointed
/// at when the liquidation happened, because an asset can be repointed.
export function liquidations(store: Store, limit: number): { count: number; liquidations: PricedLiquidation[] } {
  const rows = store.eventsByName(["Liquidated"], limit)
  const badDebt = new Map<string, EventRow>()
  for (const row of store.eventsByName(["BadDebtRealised"], limit * 2)) badDebt.set(row.txHash, row)

  const priced = rows.map((row): PricedLiquidation => {
    const asset = row.asset
    let price1e18: bigint | null = null
    let priceSource: "feed" | "manual" | null = null
    let feed: string | null = null

    if (asset) {
      feed = store.feedForAssetAt(asset, row.blockNumber)
      if (feed) {
        const point = store.priceAt(feed, row.blockNumber)
        const meta = store.feedMeta(feed)
        if (point && meta) {
          // The pool scales a feed answer to 18 decimals the same way; see SafixPool's price
          // reader. Doing it here keeps the stored answer raw and honest about its own units.
          const scale = 10n ** BigInt(18 - meta.decimals)
          price1e18 = BigInt(point.answer) * scale
          priceSource = "feed"
        }
      }
      if (price1e18 === null) {
        const manual = store.manualPriceAt(asset, row.blockNumber)
        if (manual) {
          price1e18 = BigInt(manual)
          priceSource = "manual"
        }
      }
    }

    const seized = BigInt(row.args.collateralSeized ?? "0")
    const companion = badDebt.get(row.txHash)

    return {
      block: Number(row.blockNumber),
      timestamp: row.timestamp,
      txHash: row.txHash,
      borrower: row.actor,
      asset,
      caller: (row.args.caller ?? "").toLowerCase(),
      debtCleared: row.args.debtOffset ?? "0",
      collateralSeized: row.args.collateralSeized ?? "0",
      price1e18: price1e18 === null ? null : price1e18.toString(),
      priceSource,
      feed,
      // 1e30 is the pool's own divisor: 18 collateral decimals times 1e18 of price, down to the
      // stable's 6. Matching it here means the index and the contract agree to the unit.
      collateralValue: price1e18 === null ? null : ((seized * price1e18) / 10n ** 30n).toString(),
      shortfall: companion?.args.shortfall ?? null,
      fromReserve: companion?.args.fromReserve ?? null,
      socialised: companion?.args.socialised ?? null
    }
  })

  return { count: priced.length, liquidations: priced }
}

/// Every borrower and asset pair the pool has seen. This is what the keeper reads instead of
/// replaying the whole log history on every scan.
export function positions(store: Store, openOnly: boolean) {
  const rows = store.positions(openOnly)
  return { count: rows.length, openOnly, positions: rows }
}

/// The price timeline for one feed, as the index has it.
export function priceHistory(store: Store, feed: string, limit: number) {
  const meta = store.feedMeta(feed)
  const rows = (
    store.db
      .prepare(
        "SELECT block_number, log_index, updated_at, answer FROM price WHERE feed = ? " +
          "ORDER BY block_number DESC, log_index DESC LIMIT ?"
      )
      .all(feed, limit) as { block_number: number; log_index: number; updated_at: number; answer: string }[]
  ).reverse()
  const scale = meta ? 10n ** BigInt(18 - meta.decimals) : null
  return {
    feed,
    decimals: meta?.decimals ?? null,
    description: meta?.description ?? null,
    count: rows.length,
    points: rows.map(row => ({
      block: row.block_number,
      updatedAt: row.updated_at,
      answer: row.answer,
      price1e18: scale ? (BigInt(row.answer) * scale).toString() : null
    }))
  }
}

/// What a wallet's passport has had attested and withdrawn, over time.
///
/// Answers only for an address the caller already names. The index never lists subjects, because
/// a list of attested wallets is exactly the profile the passport exists to avoid — see the
/// privacy note in README.md. Everything returned here is already public in the chain's logs;
/// the index makes it fast to read, not newly visible.
export function attestationHistory(store: Store, subject: string, limit: number) {
  const rows = store
    .eventsForActor(subject.toLowerCase(), limit, null)
    .filter(row => row.source === "registry")
  return { subject: subject.toLowerCase(), count: rows.length, events: rows.map(serialiseEvent) }
}

/// The partnership lifecycle, either all of it or one partnership's.
export function partnershipHistory(store: Store, id: string | null, limit: number) {
  const names = [
    "PartnershipCreated",
    "Funded",
    "Activated",
    "Cancelled",
    "ReturnReported",
    "SettlementApproved",
    "Settled",
    "Defaulted",
    "FunderClaimed",
    "OperatorClaimed"
  ]
  const rows = store.eventsByName(names, limit).filter(row => id === null || row.args.id === id)
  return { id, count: rows.length, events: rows.map(serialiseEvent) }
}

export const scaleToE18 = (answer: bigint, decimals: number) => answer * 10n ** BigInt(18 - decimals)
export { ONE_1E18 }
