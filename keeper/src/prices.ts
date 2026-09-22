/**
 * When a price has to be written again.
 *
 * A price goes stale by sitting still, not by moving. Once it is older than the
 * age its asset allows, the pool refuses to act on it, and to a borrower a price
 * the pool will not act on is the same as no price at all: draws, collateral
 * withdrawals and liquidations all revert. So an unchanged price is still worth
 * writing, which is the opposite of what a cache would do.
 *
 * Halfway through the allowed age leaves room for a scan to be missed and for
 * the write itself to land before the pool starts refusing anything.
 */
export function priceNeedsWriting(input: {
  current: bigint
  target: bigint
  updatedAt: bigint
  maxPriceAge: bigint
  now: bigint
}): "moved" | "ageing" | null {
  if (input.current !== input.target) return "moved"
  // An asset with no age limit cannot go stale, so an unchanged price is nothing
  // to write. Gas spent saying what the pool already knows buys nothing.
  if (input.maxPriceAge === 0n) return null
  const age = input.now - input.updatedAt
  return age * 2n >= input.maxPriceAge ? "ageing" : null
}
