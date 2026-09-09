import type { AbiEvent } from "viem"

/// Which contract a log came from. Kept as a short name rather than an address so a redeploy
/// changes the config and nothing else, and so a row is readable without a lookup table.
export type Source = "pool" | "desk" | "registry" | "feed"

export type IndexedEvent = {
  source: Source
  abi: AbiEvent
  /// Which argument names the wallet whose history this row belongs to, if any. This is what
  /// makes "show me my history" one indexed lookup rather than a scan.
  actorArg?: string
  /// Which argument names the asset, if any.
  assetArg?: string
}

const event = (source: Source, signature: string, actorArg?: string, assetArg?: string): IndexedEvent => {
  const name = signature.slice(0, signature.indexOf("("))
  const params = signature.slice(signature.indexOf("(") + 1, -1)
  const inputs = params.split(",").map(part => {
    const words = part.trim().split(/\s+/)
    const indexed = words.includes("indexed")
    return { type: words[0], name: words[words.length - 1], indexed }
  })
  return { source, abi: { type: "event", name, inputs } as AbiEvent, actorArg, assetArg }
}

/// Everything the index carries, and nothing else.
///
/// Ownership and parameter-change events are deliberately absent. They are governance history,
/// they already have a home in the timelock's own queue, and an index of them would go stale the
/// moment a parameter moved. What is here is the record of what users and the protocol did to
/// each other, which is the thing no contract call can answer after the fact.
export const INDEXED_EVENTS: IndexedEvent[] = [
  // --- the pool: liquidity ---------------------------------------------------------------
  event("pool", "Deposited(address indexed provider, uint256 amount)", "provider"),
  event("pool", "Withdrawn(address indexed provider, uint256 amount)", "provider"),
  event("pool", "GainsClaimed(address indexed provider, address indexed asset, uint256 amount)", "provider", "asset"),

  // --- the pool: borrowing ---------------------------------------------------------------
  event("pool", "CollateralLocked(address indexed borrower, address indexed asset, uint256 amount)", "borrower", "asset"),
  event("pool", "CollateralWithdrawn(address indexed borrower, address indexed asset, uint256 amount)", "borrower", "asset"),
  event("pool", "Drawn(address indexed borrower, address indexed asset, uint256 amount, uint256 fee)", "borrower", "asset"),
  event("pool", "Repaid(address indexed borrower, address indexed asset, uint256 amount)", "borrower", "asset"),
  event("pool", "PositionClosed(address indexed borrower, address indexed asset, uint256 redemptionFee)", "borrower", "asset"),

  // --- the pool: losses ------------------------------------------------------------------
  // The borrower is the actor on a liquidation, not the caller. A keeper's own history is its
  // transaction list; a borrower's history is the thing they need to be able to read back.
  event(
    "pool",
    "Liquidated(address indexed borrower, address indexed asset, address indexed caller, uint256 debtOffset, uint256 collateralSeized)",
    "borrower",
    "asset"
  ),
  event(
    "pool",
    "BadDebtRealised(address indexed borrower, address indexed asset, uint256 shortfall, uint256 fromReserve, uint256 socialised)",
    "borrower",
    "asset"
  ),

  // --- the pool: pricing -----------------------------------------------------------------
  // Which feed an asset was on, and when. A liquidation's price is only meaningful against the
  // feed the pool was actually reading at that block.
  event("pool", "PriceFeedSet(address indexed asset, address indexed feed)", undefined, "asset"),
  // The manual price, for an asset with no feed. This is the whole price history for such an
  // asset, because nothing else records it.
  event("pool", "PriceSet(address indexed asset, uint256 priceUsd1e18)", undefined, "asset"),

  // --- the desk: partnership lifecycle ---------------------------------------------------
  event(
    "desk",
    "PartnershipCreated(uint256 indexed id, address indexed operator, uint16 operatorShareBps, uint256 fundingGoal, uint64 fundingDeadline)",
    "operator"
  ),
  event("desk", "Funded(uint256 indexed id, address indexed funder, uint256 amount)", "funder"),
  event("desk", "Activated(uint256 indexed id, uint256 funded)"),
  event("desk", "Cancelled(uint256 indexed id)"),
  event("desk", "ReturnReported(uint256 indexed id, uint256 amount, uint256 totalReturned)"),
  event("desk", "SettlementApproved(uint256 indexed id, address indexed auditor)", "auditor"),
  event("desk", "Settled(uint256 indexed id)"),
  event("desk", "Defaulted(uint256 indexed id, uint256 returned)"),
  event("desk", "FunderClaimed(uint256 indexed id, address indexed funder, uint256 amount)", "funder"),
  event("desk", "OperatorClaimed(uint256 indexed id, address indexed operator, uint256 amount)", "operator"),

  // --- the registry: attestations --------------------------------------------------------
  // Indexed because the issue asks for it and because a subject should be able to read back what
  // was attested about them and when. The API never lists subjects — see the privacy note in
  // README.md. Nothing here is a fact about the person; it is a bitmask and a date, exactly what
  // is already public on chain.
  event("registry", "Attested(address indexed subject, uint8 checkMask, uint64 expiry)", "subject"),
  event("registry", "CheckAttested(address indexed subject, uint8 check, uint64 expiry)", "subject"),
  event("registry", "CheckRevoked(address indexed subject, uint8 check)", "subject"),
  event("registry", "Revoked(address indexed subject)", "subject")
]

/// Chainlink's own price history. Logs are not pruned the way state is, so this is the only
/// source that can still answer "what was the price when this position was liquidated" once the
/// node has dropped the state at that block. See README.md for the measurement.
export const ANSWER_UPDATED: AbiEvent = {
  type: "event",
  name: "AnswerUpdated",
  inputs: [
    { type: "int256", name: "current", indexed: true },
    { type: "uint256", name: "roundId", indexed: true },
    { type: "uint256", name: "updatedAt", indexed: false }
  ]
} as AbiEvent

export const bySource = (source: Source) => INDEXED_EVENTS.filter(entry => entry.source === source)
