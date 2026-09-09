import assert from "node:assert/strict"
import { test } from "node:test"
import type { EventRow } from "./db.ts"
import { Fold } from "./fold.ts"

/// The fold is the only thing that can answer for the pool's past, because the node keeps state
/// for about thirteen minutes. These tests hold it to the contract's own arithmetic: each one
/// names the line in SafixPool it is checking.

const BORROWER = "0x1111111111111111111111111111111111111111"
const ASSET = "0x2222222222222222222222222222222222222222"

let cursor = 0
const event = (name: string, args: Record<string, string>, overrides: Partial<EventRow> = {}): EventRow => {
  cursor += 1
  return {
    blockNumber: BigInt(1000 + cursor),
    logIndex: 0,
    txHash: `0xtx${cursor}`,
    timestamp: 1_700_000_000 + cursor,
    source: "pool",
    address: "0x3333333333333333333333333333333333333333",
    name,
    actor: BORROWER,
    asset: ASSET,
    args,
    ...overrides
  }
}

test("a deposit and a withdrawal move the pool by exactly their amounts", () => {
  const fold = new Fold()
  fold.apply([
    event("Deposited", { provider: BORROWER, amount: "1000000000" }),
    event("Withdrawn", { provider: BORROWER, amount: "400000000" })
  ])
  assert.equal(fold.pool.deposits, 600_000_000n)
  assert.equal(fold.pool.debt, 0n)
})

test("a draw adds the origination fee to the debt, not beside it", () => {
  // SafixPool L697-L715: newDebt = debt + amount + fee, and totalDebt rises by amount + fee.
  // An index that recorded only `amount` would show every borrower owing less than they do.
  const fold = new Fold()
  fold.apply([event("Drawn", { borrower: BORROWER, asset: ASSET, amount: "1000000000", fee: "5000000" })])

  const position = fold.positions.get(`${BORROWER}:${ASSET}`)
  assert.ok(position)
  assert.equal(position.debt, 1_005_000_000n, "debt carries the fee")
  assert.equal(position.totalDrawn, 1_000_000_000n, "totalDrawn does not")
  assert.equal(fold.pool.debt, 1_005_000_000n)
})

test("closing a position clears debt the event never states", () => {
  // PositionClosed carries only the redemption fee. The debt it cleared is the fold's to supply,
  // and it is the one pool quantity no single log can answer for.
  const fold = new Fold()
  fold.apply([
    event("CollateralLocked", { borrower: BORROWER, asset: ASSET, amount: "5000000000000000000" }),
    event("Drawn", { borrower: BORROWER, asset: ASSET, amount: "1000000000", fee: "5000000" }),
    event("Repaid", { borrower: BORROWER, asset: ASSET, amount: "5000000" }),
    event("PositionClosed", { borrower: BORROWER, asset: ASSET, redemptionFee: "3000000" })
  ])

  assert.equal(fold.pool.debt, 0n, "the pool's debt falls by whatever was left")
  const position = fold.positions.get(`${BORROWER}:${ASSET}`)
  assert.equal(position?.debt, 0n)
  assert.equal(position?.collateral, 0n)
  assert.equal(position?.totalDrawn, 0n)
})

test("a liquidation with no shortfall takes the whole offset from providers", () => {
  // SafixPool L883: totalDeposits -= lpLoss, and with received >= offset the lpLoss is the whole
  // offset. That is not a loss — the pool bought collateral with it — but the deposits do fall.
  const fold = new Fold()
  fold.apply([
    event("Deposited", { provider: BORROWER, amount: "10000000000" }),
    event("Drawn", { borrower: BORROWER, asset: ASSET, amount: "1000000000", fee: "0" }),
    event("Liquidated", {
      borrower: BORROWER,
      asset: ASSET,
      caller: "0x4444444444444444444444444444444444444444",
      debtOffset: "1000000000",
      collateralSeized: "5000000000000000000"
    })
  ])

  assert.equal(fold.pool.debt, 0n)
  assert.equal(fold.pool.deposits, 9_000_000_000n, "deposits fall by the debt cancelled")
})

test("the reserve's share of a shortfall does not fall on providers", () => {
  // SafixPool L815-L832: providers carry `offset - fromReserve`. BadDebtRealised is emitted from
  // _settleShortfall before Liquidated, so the fold sees the companion first — that ordering is
  // load-bearing and this test would fail if it changed.
  const fold = new Fold()
  const tx = "0xshared"
  fold.apply([
    event("Deposited", { provider: BORROWER, amount: "10000000000" }),
    event("Drawn", { borrower: BORROWER, asset: ASSET, amount: "1000000000", fee: "0" }),
    event(
      "BadDebtRealised",
      { borrower: BORROWER, asset: ASSET, shortfall: "300000000", fromReserve: "200000000", socialised: "100000000" },
      { txHash: tx, logIndex: 0 }
    ),
    event(
      "Liquidated",
      {
        borrower: BORROWER,
        asset: ASSET,
        caller: "0x4444444444444444444444444444444444444444",
        debtOffset: "1000000000",
        collateralSeized: "5000000000000000000"
      },
      { txHash: tx, logIndex: 1 }
    )
  ])

  // 1,000 cancelled, of which the reserve paid 200: providers carry 800.
  assert.equal(fold.pool.deposits, 10_000_000_000n - 800_000_000n)
})

test("a partial liquidation takes its share of totalDrawn with it", () => {
  // SafixPool L860. Without this the borrower is charged a redemption fee at close on draws a
  // liquidation already settled — the bug fixed in #1, kept honest here.
  const fold = new Fold()
  fold.apply([
    event("Drawn", { borrower: BORROWER, asset: ASSET, amount: "1000000000", fee: "0" }),
    event("Liquidated", {
      borrower: BORROWER,
      asset: ASSET,
      caller: "0x4444444444444444444444444444444444444444",
      debtOffset: "400000000",
      collateralSeized: "2000000000000000000"
    })
  ])

  const position = fold.positions.get(`${BORROWER}:${ASSET}`)
  assert.equal(position?.debt, 600_000_000n)
  assert.equal(position?.totalDrawn, 600_000_000n, "40% of the debt went, so 40% of totalDrawn went")
})

test("events that carry no arithmetic are stored but never move the pool", () => {
  const fold = new Fold()
  const points = fold.apply([
    event("Attested", { subject: BORROWER, checkMask: "31", expiry: "1800000000" }, { source: "registry" }),
    event("Funded", { id: "1", funder: BORROWER, amount: "20000000000" }, { source: "desk" }),
    event("PriceFeedSet", { asset: ASSET, feed: "0x5555555555555555555555555555555555555555" })
  ])
  assert.equal(points.length, 0, "no pool point for history without arithmetic")
  assert.equal(fold.pool.deposits, 0n)
  assert.equal(fold.pool.debt, 0n)
})

test("a pool point is emitted for every event that moves the pool, and only those", () => {
  const fold = new Fold()
  const points = fold.apply([
    event("Deposited", { provider: BORROWER, amount: "1000000000" }),
    event("CollateralLocked", { borrower: BORROWER, asset: ASSET, amount: "5000000000000000000" }),
    event("Drawn", { borrower: BORROWER, asset: ASSET, amount: "500000000", fee: "2500000" })
  ])

  assert.equal(points.length, 2, "locking collateral moves neither deposits nor debt")
  assert.equal(points[0].state.deposits, 1_000_000_000n)
  assert.equal(points[1].state.debt, 502_500_000n)
})

test("folding in pieces agrees with folding all at once", () => {
  // The sync loop folds each batch as it arrives; a reorg refolds everything. The two must land
  // on the same numbers or the index disagrees with itself after a rewind.
  const script = [
    event("Deposited", { provider: BORROWER, amount: "8000000000" }),
    event("CollateralLocked", { borrower: BORROWER, asset: ASSET, amount: "5000000000000000000" }),
    event("Drawn", { borrower: BORROWER, asset: ASSET, amount: "1000000000", fee: "5000000" }),
    event("Repaid", { borrower: BORROWER, asset: ASSET, amount: "200000000" }),
    event("Withdrawn", { provider: BORROWER, amount: "1000000000" })
  ]

  const whole = new Fold()
  whole.apply(script)

  const pieces = new Fold()
  pieces.apply(script.slice(0, 2))
  pieces.apply(script.slice(2, 3))
  pieces.apply(script.slice(3))

  assert.deepEqual(pieces.pool, whole.pool)
  assert.deepEqual(
    [...pieces.positions.entries()].map(([id, value]) => [id, value.debt, value.collateral, value.totalDrawn]),
    [...whole.positions.entries()].map(([id, value]) => [id, value.debt, value.collateral, value.totalDrawn])
  )
})
