import assert from "node:assert/strict"
import { test } from "node:test"
import { Store, type EventRow } from "./db.ts"
import { actionHistory, liquidations, poolHistory } from "./queries.ts"

const BORROWER = "0x1111111111111111111111111111111111111111"
const OTHER = "0x9999999999999999999999999999999999999999"
const ASSET = "0x2222222222222222222222222222222222222222"
const FEED = "0x57558663AF6d0212a8E152BdcB78f130aCC6486C"
const POOL = "0x3333333333333333333333333333333333333333"

const fresh = () => new Store(":memory:")

const row = (over: Partial<EventRow> & Pick<EventRow, "name" | "blockNumber" | "args">): EventRow => ({
  logIndex: 0,
  txHash: "0xtx",
  timestamp: 1_700_000_000,
  source: "pool",
  address: POOL,
  actor: BORROWER,
  asset: ASSET,
  ...over
})

test("a liquidation is priced from the feed's own log, not from a historical call", () => {
  // The node drops state after about thirteen minutes, so a call cannot answer for the block a
  // liquidation happened at. Logs are not pruned, so the feed's AnswerUpdated is the last durable
  // copy of the price the pool acted on.
  const store = fresh()
  store.setFeedMeta(FEED, 8, "AMZN / USD")
  store.writeBatch(
    [
      row({ name: "PriceFeedSet", blockNumber: 100n, actor: null, args: { asset: ASSET, feed: FEED } }),
      row({
        name: "Liquidated",
        blockNumber: 300n,
        txHash: "0xliq",
        args: { borrower: BORROWER, asset: ASSET, caller: OTHER, debtOffset: "1000000000", collateralSeized: "5000000000000000000" }
      })
    ],
    [
      // Two rounds before the liquidation and one after. The one in force is the later of the two
      // that precede it; the later round must not leak backwards.
      { feed: FEED, blockNumber: 150n, logIndex: 0, updatedAt: 1_700_000_100, answer: "20000000000" },
      { feed: FEED, blockNumber: 250n, logIndex: 0, updatedAt: 1_700_000_200, answer: "24524826000" },
      { feed: FEED, blockNumber: 400n, logIndex: 0, updatedAt: 1_700_000_300, answer: "30000000000" }
    ],
    500n
  )

  const result = liquidations(store, 10)
  assert.equal(result.count, 1)
  const [liquidation] = result.liquidations
  assert.equal(liquidation.priceSource, "feed")
  assert.equal(liquidation.feed, FEED)
  // 24524826000 at 8 decimals is $245.24826, which scaled to 18 decimals is x 1e10.
  assert.equal(liquidation.price1e18, "245248260000000000000")
  // 5 tokens at $245.24826 is $1,226.24, in the stable's 6 decimals.
  assert.equal(liquidation.collateralValue, "1226241300")
  store.close()
})

test("a liquidation with no price behind it says so rather than guessing", () => {
  const store = fresh()
  store.writeBatch(
    [
      row({
        name: "Liquidated",
        blockNumber: 300n,
        args: { borrower: BORROWER, asset: ASSET, caller: OTHER, debtOffset: "1000000000", collateralSeized: "5000000000000000000" }
      })
    ],
    [],
    500n
  )

  const [liquidation] = liquidations(store, 10).liquidations
  assert.equal(liquidation.price1e18, null)
  assert.equal(liquidation.priceSource, null)
  assert.equal(liquidation.collateralValue, null)
  store.close()
})

test("an asset with a manual price is priced from PriceSet", () => {
  const store = fresh()
  store.writeBatch(
    [
      row({ name: "PriceSet", blockNumber: 100n, actor: null, args: { asset: ASSET, priceUsd1e18: "1004200000000000000" } }),
      row({
        name: "Liquidated",
        blockNumber: 300n,
        args: { borrower: BORROWER, asset: ASSET, caller: OTHER, debtOffset: "1000000", collateralSeized: "1000000000000000000" }
      })
    ],
    [],
    500n
  )

  const [liquidation] = liquidations(store, 10).liquidations
  assert.equal(liquidation.priceSource, "manual")
  assert.equal(liquidation.price1e18, "1004200000000000000")
  store.close()
})

test("a feed the asset was repointed away from does not price a later liquidation", () => {
  // An asset can be moved to a different feed. Pricing against whichever feed is current today
  // would silently misprice everything that happened before the move.
  const store = fresh()
  const OLD = "0x1010101010101010101010101010101010101010"
  store.setFeedMeta(OLD, 8, "old")
  store.setFeedMeta(FEED, 8, "new")
  store.writeBatch(
    [
      row({ name: "PriceFeedSet", blockNumber: 100n, logIndex: 0, actor: null, args: { asset: ASSET, feed: OLD } }),
      row({ name: "PriceFeedSet", blockNumber: 200n, logIndex: 0, actor: null, args: { asset: ASSET, feed: FEED } }),
      row({
        name: "Liquidated",
        blockNumber: 150n,
        args: { borrower: BORROWER, asset: ASSET, caller: OTHER, debtOffset: "1", collateralSeized: "1000000000000000000" }
      })
    ],
    [
      { feed: OLD, blockNumber: 110n, logIndex: 0, updatedAt: 1, answer: "10000000000" },
      { feed: FEED, blockNumber: 210n, logIndex: 0, updatedAt: 2, answer: "99900000000" }
    ],
    500n
  )

  const [liquidation] = liquidations(store, 10).liquidations
  assert.equal(liquidation.feed, OLD, "the feed in force at block 150, not the one set later")
  assert.equal(liquidation.price1e18, "100000000000000000000")
  store.close()
})

test("a shortfall is reported from its own event, not derived", () => {
  const store = fresh()
  store.writeBatch(
    [
      row({
        name: "BadDebtRealised",
        blockNumber: 300n,
        logIndex: 0,
        txHash: "0xliq",
        args: { borrower: BORROWER, asset: ASSET, shortfall: "300000000", fromReserve: "200000000", socialised: "100000000" }
      }),
      row({
        name: "Liquidated",
        blockNumber: 300n,
        logIndex: 1,
        txHash: "0xliq",
        args: { borrower: BORROWER, asset: ASSET, caller: OTHER, debtOffset: "1000000000", collateralSeized: "5000000000000000000" }
      })
    ],
    [],
    500n
  )

  const [liquidation] = liquidations(store, 10).liquidations
  assert.equal(liquidation.shortfall, "300000000")
  assert.equal(liquidation.fromReserve, "200000000")
  assert.equal(liquidation.socialised, "100000000")
  store.close()
})

test("a wallet's history is its own and nobody else's", () => {
  const store = fresh()
  store.writeBatch(
    [
      row({ name: "Deposited", blockNumber: 10n, args: { provider: BORROWER, amount: "1" } }),
      row({ name: "Deposited", blockNumber: 11n, actor: OTHER, args: { provider: OTHER, amount: "2" } }),
      row({ name: "Withdrawn", blockNumber: 12n, args: { provider: BORROWER, amount: "3" } })
    ],
    [],
    100n
  )

  const mine = actionHistory(store, BORROWER, 50, null)
  assert.equal(mine.count, 2)
  assert.deepEqual(
    mine.events.map(entry => entry.name),
    ["Withdrawn", "Deposited"],
    "newest first"
  )
  assert.equal(actionHistory(store, OTHER, 50, null).count, 1)
  store.close()
})

test("history is case-insensitive in the address, because a checksum is not a fact", () => {
  const store = fresh()
  store.writeBatch([row({ name: "Deposited", blockNumber: 10n, args: { provider: BORROWER, amount: "1" } })], [], 100n)
  assert.equal(actionHistory(store, BORROWER.toUpperCase().replace("0X", "0x"), 50, null).count, 1)
  store.close()
})

test("history pages backwards without repeating or skipping a row", () => {
  const store = fresh()
  store.writeBatch(
    Array.from({ length: 5 }, (_, index) =>
      row({ name: "Deposited", blockNumber: BigInt(10 + index), args: { provider: BORROWER, amount: String(index) } })
    ),
    [],
    100n
  )

  const first = actionHistory(store, BORROWER, 2, null)
  assert.deepEqual(first.events.map(entry => entry.block), [14, 13])
  assert.equal(first.nextBefore, 13)

  const second = actionHistory(store, BORROWER, 2, BigInt(first.nextBefore!))
  assert.deepEqual(second.events.map(entry => entry.block), [12, 11])

  const third = actionHistory(store, BORROWER, 2, BigInt(second.nextBefore!))
  assert.deepEqual(third.events.map(entry => entry.block), [10])
  assert.equal(third.nextBefore, null, "a short page is the last page")
  store.close()
})

test("utilisation is computed from the point, and a pool with nothing in it is not divided by zero", () => {
  const store = fresh()
  store.writePoolPoint(10n, 0, 1, 0n, 0n)
  store.writePoolPoint(11n, 0, 2, 1_000_000_000n, 250_000_000n)
  const history = poolHistory(store, 10)
  assert.equal(history.points[0].utilisationBps, 0)
  assert.equal(history.points[1].utilisationBps, 2500)
  assert.deepEqual(history.points.map(point => point.block), [10, 11], "oldest first, so it plots")
  store.close()
})
