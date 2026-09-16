# Risk parameter policy

How every risk number on `SafixPool` is chosen, and who may change it.

This document exists so that a parameter is never set by whoever happens to be at the keyboard. A number that cannot be justified from what is written here does not go onchain.

## The parameters

| Parameter | Scope | Set by | What it bounds |
| --- | --- | --- | --- |
| `maxLtvBps` | asset | `configureAsset` | how much may be drawn against collateral at all |
| `liqThresholdBps` | asset | `configureAsset` | where the position becomes liquidatable |
| `debtCap` | asset | `setAssetCaps` | stable owed against one asset at once |
| `collateralCap` | asset | `setAssetCaps` | how much of one asset the pool will hold |
| `maxPriceAge` | asset | `setPriceGuard` | how stale a price may be |
| `maxDeviationBps` | asset | `setPriceGuard` | how far a price may move between updates |
| `minPrice1e18` / `maxPrice1e18` | asset | `setPriceGuard` | the band the asset is expected to trade in |
| `globalDebtCeiling` | pool | `setRiskLimits` | total lending across every asset |
| `minPositionDebt` | pool | `setRiskLimits` | the smallest position that may stay open |
| `minLiquidityBuffer` | pool | `setRiskLimits` | liquidity a draw must leave behind |
| `reserveFeeShareBps` | pool | `setReserveFeeShare` | the share of each origination fee that funds the reserve |
| `originationFeeBps` / `redemptionFeeBps` | pool | `setFees` | what a draw and a close cost |
| `liquidationIncentiveBps` | pool | `setLiquidationIncentive` | the keeper's share of seized collateral |

## Asset classes

An asset is placed in a class before any number is chosen. The class sets the starting point; the asset's own liquidity moves it from there, and only downwards.

### Class A — cash equivalents and short-duration treasuries

Daily moves measured in basis points, redemption backed by an instrument that matures. `tBILL` is here.

- **Max LTV 80%**, liquidation threshold **90%**. The ten point gap is roughly forty times a normal daily move, which is the room a keeper needs on a bad day.
- **Price age** matched to the feed heartbeat, typically 24 hours; these feeds do not update often because the price does not move.
- **Deviation limit 10%.** A short treasury moving ten percent between two prints is a feed fault, not a market.
- **Band** ±50% of par. Wide, because the guard is there to catch a broken feed rather than to express a view.

### Class B — broad index and sector funds

Diversified, deep, but equity volatility.

- **Max LTV 65%**, threshold **80%**.
- **Price age** matched to heartbeat, typically one hour during market hours.
- **Deviation limit 15%.** An index gapping further than that in one print is a halt or a feed fault.
- **Band** ±80% of the price at onboarding, revisited annually.

### Class C — single stocks

One earnings miss is a 20% gap. `bNVDA` is here.

- **Max LTV 55%**, threshold **70%**. The fifteen point gap absorbs a single-name gap that an index would never see.
- **Price age** matched to heartbeat, typically one hour.
- **Deviation limit 20%,** which is wide enough not to fight ordinary earnings moves and narrow enough to catch a fat finger.
- **Band** ±90% of the onboarding price.
- No single stock starts above a 55% LTV regardless of how liquid it looks. Liquidity in a single name is a fair-weather property.

### Class D — commodities

No earnings, but macro gaps and thinner tokenized liquidity. `tGOLD` is here.

- **Max LTV 65%**, threshold **80%**.
- **Deviation limit 15%.**
- **Band** ±70% of the onboarding price.

## How the caps are sized

Classes set the LTV. Caps are sized from the pool and from the market, and the tighter of the two wins.

**Debt cap, from the pool.** No asset starts above a share of the pool that the pool could absorb losing entirely:

| Class | Opening debt cap |
| --- | --- |
| A | 40% of pool size |
| B | 25% |
| C | 15% |
| D | 15% |

The classes do not have to sum to 100%; `globalDebtCeiling` is what stops the total, and an asset's cap is a ceiling rather than an allocation.

**Debt cap, from the market.** The cap must also be small enough that the collateral behind it can actually be sold. The test is a full liquidation of the asset's entire capped position against **one day of that token's observed volume**, at no more than **20% of it**. If a cap implies selling more than that in a day, the cap comes down until it does not. This is the check that catches a thin-liquidity token that looks fine on price alone, which is the failure the caps exist to prevent.

**Collateral cap** follows from the debt cap: the collateral required to support it at the asset's own max LTV, plus 25% for the collateral that sits there over-collateralised. It is a second, blunter bound in case an LTV is later raised without the cap being revisited.

**`globalDebtCeiling`** starts at **50% of pool size**. Utilisation above that leaves too little liquidity for providers to leave and for liquidations to be absorbed at the same time.

**`minLiquidityBuffer`** starts at **10% of pool size**. It is the floor a draw may not take liquidity below. It does not bound withdrawals: it is there to stop borrowing from consuming the room that exits need, not to hold providers in.

**`minPositionDebt`** is set to **500 stable units**, reviewed if gas on the chain changes by an order of magnitude. The number is a multiple of what a liquidation costs to send, so that seizing a position is always worth more than the transaction that seizes it. Below this a position would sit unliquidatable, which is worse than not opening it.

Raising it applies to positions that are already open. A repayment that would leave a position under the floor takes the whole debt instead of being refused, so a raise narrows how an open position can be repaid without closing any exit — and the floor is never a reason a borrower cannot cure an unhealthy position by paying it down.

## Bad debt and the reserve

When a price gaps through the liquidation threshold, the pool cancels more debt than the collateral it receives is worth. That gap is a real loss and it has to land somewhere named.

**The policy: the reserve absorbs a shortfall first, and only what it cannot cover is socialised across providers — recorded in `badDebt`, never absorbed silently.**

Two alternatives were considered and rejected. Holding the loss against protocol fees alone fails because fees are revenue that gets withdrawn; a buffer that can be spent elsewhere is not a buffer. Socialising first fails because a provider should not be the first line of defence against a gap they had no part in creating.

**`reserveFeeShareBps` starts at 2,500** — a quarter of every origination fee. This ties the buffer to the volume that creates the risk: the more the pool lends, the faster its own defence grows. It is capped at 5,000 in the contract, because past half the protocol stops funding its own operation, and a reserve nobody can afford to operate around is not risk management.

**The reserve is seeded at 2% of pool size at deploy**, so the first gap-down does not land on providers before fees have had time to build it. `fundReserve` is open to anyone, so a partner or the protocol can top it up without a privileged path; `withdrawReserve` is owner-only and cannot reach further than the reserve holds.

The reserve sits in the pool's balance but is excluded from available liquidity, exactly as protocol fees are. It is neither lendable nor withdrawable by providers.

**Target size.** The reserve should cover a **full gap-down of the largest single position the caps allow**, at a 50% collateral price shock. With class C capped at 15% of the pool and a 55% LTV, that is roughly 7% of pool size. Below that target, raise `reserveFeeShareBps`; sustained above it, the excess may be withdrawn to the treasury. Reviewed on the same quarterly cycle as everything else here.

**Underwater dust.** A position whose remaining collateral is worth less than the gas to liquidate it will never be taken by a keeper: their incentive is a share of nearly nothing. `absorbBadDebt` lets the owner clear it — the pool takes the collateral, cancels the debt, and books the gap through the same reserve-then-socialise path, with no keeper incentive carved out because there is no keeper. It only accepts a position that is both liquidatable and below `minPositionDebt` in collateral value, so it can never close a healthy loan.

## Onboarding a new asset

In order. Each step blocks the next.

1. Place the asset in a class, and write down why.
2. Verify the token contract against the official registry, and read its `uiMultiplier`.
3. Confirm the Chainlink feed address, decimals and heartbeat from Chainlink's own directory, not from a third party.
4. Gather thirty days of observed volume. Compute the market-side debt cap.
5. `configureAsset` with the class LTV and threshold, then `setPriceFeed`.
6. `setPriceGuard` with the heartbeat as `maxPriceAge`, the class deviation limit, and the class band around the current price.
7. `setAssetCaps` with the lower of the pool-side and market-side debt caps, and the collateral cap derived from it.
8. Verify `currentPrice` against an independent source within tolerance before any draw is possible.

An asset is never enabled and left uncapped. `configureAsset` followed by nothing else is an incomplete onboarding, and the caps default to zero, which means uncapped.

## Who signs off

| Change | Authority | Waits |
| --- | --- | --- |
| `maxLtvBps`, `liqThresholdBps`, `debtCap`, `collateralCap` | multisig, through the timelock | yes |
| `globalDebtCeiling`, `minPositionDebt`, `minLiquidityBuffer` | multisig, through the timelock | yes |
| Price guards, price feed swaps | multisig, through the timelock | yes |
| Fees, `liquidationIncentiveBps`, `reserveFeeShareBps` | multisig, through the timelock | yes |
| The desk's auditor | multisig, through the timelock | yes |
| Pausing | guardian alone | **no** |
| Unpausing | multisig, directly | **no** |
| Guardian appointment, price updater, passport registry | multisig, directly | no |
| Collecting fees, withdrawing from the reserve | multisig, directly | no |
| Posting a price | price updater, every heartbeat | no |
| Onboarding a new asset | multisig, through the timelock, with the onboarding record above completed first | yes |

The split is between what changes user risk and what does not. An LTV binds a position that already exists, so it waits. A pause removes risk and cannot wait — a brake that waits is not a brake. Unpausing is immediate too: an incident is not the moment to add two days, and the multisig has already had to agree.

This is enforced onchain, not by convention. Risk parameters carry `onlyTimelock`, so the multisig cannot reach them directly even though it owns the contracts.

### The multisig and the timelock

| | Testnet |
| --- | --- |
| Safe | [`0x9c41ef802d8435ceed762173a167f0696df319e9`](https://explorer.testnet.chain.robinhood.com/address/0x9c41ef802d8435ceed762173a167f0696df319e9), v1.4.1 |
| Signers | `0x0dD1f46b…`, `0x2FbD3F25…`, `0x6Fdf7e5b…` |
| Threshold | **2 of 3** |
| Timelock delay | **48 hours** |

Two of three is the smallest threshold where no single compromised key moves anything and no single lost key locks everything. The mainnet signer set is a separate decision, made with the mainnet launch, and belongs to people rather than to keys generated for a testnet.

The delay has a floor of **24 hours in the contract**, which the admin cannot cross: `setDelay` runs only through the timelock itself, so shortening the delay is announced as far in advance as any other change. A queued operation expires after a **14-day grace period**, so a change nobody remembers cannot be executed a year later by whoever finds it.

Cancelling is immediate. Stopping a change is never the thing that needs slowing down.

**A change needs, before it is proposed:** the parameter, its current and proposed value, which class rule it follows or why it departs from one, what changed to prompt it, and what it costs if it is wrong. A proposal that cannot answer the last question is not ready.

**Loosening and tightening are not symmetric.** Raising an LTV, raising a cap, or widening a band increases what the pool can lose and goes through the full timelock without exception. Lowering a cap or narrowing a band reduces exposure and may move at the timelock's minimum. Lowering a cap below current usage is deliberately allowed: it stops growth without forcing open positions to unwind, which would be a liquidation by another name.

## Review

Every parameter is reviewed **quarterly**, and immediately after any of:

- a liquidation that left bad debt
- a price guard rejecting a price that turned out to be correct
- a feed changing its heartbeat or decimals
- an asset's observed volume falling by more than half from its onboarding figure
- the pool changing in size by more than 50% since the caps were last set, since every cap above is expressed as a share of it
