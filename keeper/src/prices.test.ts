import assert from "node:assert/strict"
import { test } from "node:test"
import { priceNeedsWriting } from "./prices.ts"

const at = (updatedAt: bigint, now: bigint, maxPriceAge: bigint, current = 100n, target = 100n) =>
  priceNeedsWriting({ current, target, updatedAt, maxPriceAge, now })

test("a price that moved is written whatever its age", () => {
  assert.equal(at(1_000n, 1_001n, 3_600n, 100n, 101n), "moved")
})

test("a fresh price that did not move is left alone", () => {
  assert.equal(at(1_000n, 1_100n, 3_600n), null)
})

test("an unchanged price is written once it is halfway through its allowed age", () => {
  // The pool would still act on this one. Waiting for it to stop is the mistake:
  // the write has to land before the age runs out, not after.
  assert.equal(at(1_000n, 1_000n + 1_800n, 3_600n), "ageing")
})

test("a price past its allowed age is written", () => {
  assert.equal(at(1_000n, 1_000n + 7_200n, 3_600n), "ageing")
})

test("the hour an equity allows is what decides, not the day a treasury allows", () => {
  // bNVDA allows an hour and tBILL a day. Half an hour into both, only the
  // equity needs writing, and a keeper using one interval for every asset would
  // either let the equity go stale or write the treasury all day for nothing.
  const halfAnHour = 1_800n
  assert.equal(at(0n, halfAnHour, 3_600n), "ageing")
  assert.equal(at(0n, halfAnHour, 86_400n), null)
})

test("an asset with no age limit is never written for ageing", () => {
  assert.equal(at(0n, 10n ** 9n, 0n), null)
})
