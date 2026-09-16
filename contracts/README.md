# Safix contracts

Foundry workspace for the Safix protocol on Robinhood Chain.

## Contracts

- `SafixPool.sol`: the core. USDC-denominated stability pool with Liquity-style product-sum accounting (scale-aware, so precision survives arbitrarily heavy liquidation sequences), per-asset collateral configuration, zero-interest draws with a one-time origination fee added to debt, a redemption fee at position close, partial liquidation with a keeper incentive carved from seized collateral, Chainlink AggregatorV3 feeds per asset with manual price fallback, the oracle safety layer described below, and an optional passport gate on draws.
- `SafixTimelock.sol`: the delay every risk parameter passes through. Queue, wait, execute; cancel immediately. Its own delay and admin are behind the delay too.
- `Guardable.sol`: the guardian role and the pause bitmask, inherited by the pool and the desk. Pausing is a guardian or owner action with no timelock; unpausing is the owner's alone.
- `PartnershipDesk.sol`: the profit and loss sharing track. Owner-created partnerships, pro-rata funding, capital to the operator on activation, onchain return reports, optional auditor-approved settlement, profit split at the agreed ratio, genuine losses on the capital. Every partnership carries a reporting deadline: past it without a settlement, anyone may declare a default, funders recover what was returned pro rata, and the operator's profit share is forfeit. The agreement template, the auditor's mandate and the full runbook: [docs/partnership-desk.md](../docs/partnership-desk.md).
- `PassportRegistry.sol`: the reusable private collateral passport. Five named checks as bits, each with its own expiry, written by an attester who can do nothing else; `isEligible` is the single question integrated platforms ask, and the evidence behind it never goes onchain. Renew or withdraw one check without disturbing the others. Who attests what, on what evidence, and for how long: [docs/passport-policy.md](../docs/passport-policy.md).

## Oracle safety

A price is only acted on once it has cleared four checks. `priceStatus(asset)` answers whether it has, and says why not when it has not, without ever reverting.

**The sequencer.** Robinhood Chain is an Arbitrum Orbit rollup. A price feed can keep returning a recent-looking answer while the sequencer is down, and can return a perfectly good one the instant it comes back, before any borrower has had a chance to react. `setSequencerUptimeFeed(feed, gracePeriod)` wires Chainlink's L2 sequencer uptime feed: answer `0` is up, `1` is down, and `startedAt` is when that last changed. Prices are refused while the sequencer is down and for `gracePeriod` after it returns. A feed that reverts, or one whose round never started, counts as down. **Chainlink has not published an uptime feed for Robinhood Chain, and is no longer adding them to new networks.** Until one exists the address is left unset, which means no sequencer check — the behaviour the pool had before. When one is published, wiring it is a single owner transaction and needs no redeploy.

**Per-asset sanity bounds.** `setPriceGuard(asset, maxPriceAge, maxDeviationBps, minPrice1e18, maxPrice1e18)` sets, for one asset:

| Field | Refuses a price that |
| --- | --- |
| `maxPriceAge` | is older than this. Set it to the feed's own heartbeat — a treasury feed on a daily cadence and an equity feed on an hourly one cannot share a deadline, which is why age is per asset rather than global. |
| `maxDeviationBps` | moved further than this from the previous update. Consecutive feed rounds are compared, so a quiet market never drifts into a rejection; a manual price is compared against the one it replaces. |
| `minPrice1e18` / `maxPrice1e18` | falls outside the band the asset is expected to trade in. |

Every field is off when zero, so an asset with no guard behaves exactly as it did before guards existed. The same bounds apply to `setPrice`, so a mistaken or compromised price updater cannot post a number the pool would refuse from an oracle.

**What happens when a price cannot be used.** Anything that puts a borrower at risk is blocked; nothing that lets someone get out is.

| Action | Needs a usable price | While the price is unusable |
| --- | --- | --- |
| `deposit`, `withdraw`, `claimGains` | no | open |
| `lockCollateral` | no | open — adding collateral cannot make a position worse |
| `withdrawCollateral`, no debt against it | no | open |
| `withdrawCollateral`, against a live loan | yes | **blocked** |
| `draw` | yes | **blocked** |
| `repay` | no | open |
| `closePosition` | no | open, collateral included |
| `liquidate` | yes | **blocked** |

`isLiquidatable` returns false rather than reverting whenever the price is unusable, so a keeper scanning many positions is not knocked over by one bad feed, and no keeper is ever told to seize collateral on a number nobody could have reacted to.

## Risk caps

No asset can absorb the whole pool. `setAssetCaps(asset, debtCap, collateralCap)` bounds one asset; `setRiskLimits(globalDebtCeiling, minPositionDebt, minLiquidityBuffer)` bounds the pool. Every limit is off at zero, so an unconfigured pool behaves as it did before.

| Limit | Refuses |
| --- | --- |
| `debtCap` | a draw that would take stable owed against this asset past the cap. Reverts `asset cap`. |
| `collateralCap` | a lock that would take the pool's holding of this asset past the cap. Reverts `collateral cap`. |
| `globalDebtCeiling` | a draw that would take total debt past the ceiling. Reverts `global cap`. |
| `minPositionDebt` | a draw that opens a position too small to be worth liquidating. Reverts `position too small`. A repayment that would leave one is completed rather than refused; see below. |
| `minLiquidityBuffer` | a draw that would take available liquidity below the floor. Reverts `illiquid`. |

Caps count debt including the origination fee, because that is what the pool is owed. The liquidity buffer counts the fee too: available liquidity falls by the fee as well as the amount, since the fee is set aside as protocol revenue rather than left lendable.

`assetDebt` and `assetCollateral` are accumulators, and `assetDebtHeadroom`, `assetCollateralHeadroom`, `globalDebtHeadroom` and `drawableLiquidity` report the remaining room. An interface can show how much is left before a signature rather than discovering the boundary through a revert; an uncapped limit reports the maximum, so a minimum across limits needs no special-casing.

Three behaviours worth knowing. A cap may be lowered below current usage: that stops further growth without forcing open positions to unwind, which would be a liquidation by another name. A partial liquidation that would leave less than `minPositionDebt` behind takes the whole position instead, so the floor cannot be walked around by liquidating around it.

And a repayment that would leave less than `minPositionDebt` behind takes the whole debt instead, the same way. Refusing it would refuse the one repayment that cures an unhealthy position whenever the floor sits above the healthy debt, and would leave a position under a floor raised after it opened repayable only in full. It escalates only when the borrower has approved and holds the whole debt, and reverts `position too small` otherwise; nothing moves in that case. `Repaid` reports the amount actually taken. Either way the position ends at zero or at the floor and above, never in between. An interface that approves exactly the amount it asks to repay will get the refusal rather than the escalation: to cure in one call it has to approve the whole debt.

How each number is chosen, per asset class, and who may change it: [docs/risk-parameters.md](../docs/risk-parameters.md).

## Bad debt and the reserve

A price that gaps through the liquidation threshold leaves the pool cancelling more debt than the collateral it receives is worth. That gap is a real loss, and it now lands somewhere with a name.

`reserve` holds stable against exactly this. It is funded by `reserveFeeShareBps` of every origination fee, topped up by anyone through `fundReserve`, withdrawable only by the owner and only up to what it holds. It sits in the pool's balance but is excluded from available liquidity, the same way protocol fees are: neither lendable nor withdrawable by providers.

On a liquidation the pool compares the debt it cancels against what the seized collateral is actually worth. If the collateral falls short, the reserve pays the difference; whatever the reserve cannot cover is socialised across providers and added to `badDebt`, and `BadDebtRealised` records the split. Providers lose the offset less whatever the reserve paid on their behalf, so total claims fall by exactly the offset either way and the books stay balanced.

`absorbBadDebt(borrower, asset)` handles the position nobody will liquidate: one whose remaining collateral is worth less than the gas to take it. The pool takes the collateral, cancels the debt, and books the gap the same way, with no keeper incentive carved out because there is no keeper. Owner only, and only for a position that is both liquidatable and genuinely dust.

The invariant suite holds `balance + debt == deposits + fees + reserve` across randomised sequences with the reserve live, so every unit of stable is claimed by exactly one of the three and a shortfall moves a claim rather than destroying one.

The policy behind the numbers, and the reserve's target size: [docs/risk-parameters.md](../docs/risk-parameters.md).

## Ownership and the timelock

Three roles, deliberately separate.

**The multisig owns the contracts.** It appoints the guardian, unpauses, collects fees, withdraws from the reserve, and sets the price updater. None of those change what an existing position is worth.

**The timelock holds the risk parameters.** LTVs, liquidation thresholds, caps, the global ceiling, the position floor, the liquidity buffer, price guards, feed swaps, fees, the liquidation incentive, the reserve share, and the desk's auditor all carry `onlyTimelock`. The multisig **cannot reach them directly** even though it owns the contracts; it has to queue a change, wait, and execute. That is enforced onchain rather than by convention.

A timelock does not make a decision better. What it buys is a window: a change is visible onchain, with its full calldata in the `Queued` event, before it binds anyone. A lender who disagrees with a new LTV can leave before it applies to them.

**The guardian holds the brake, outside all of it.** Pausing is immediate and needs no delay and no second signature.

`SafixTimelock` enforces a 24-hour floor on its own delay, and `setDelay` and `setAdmin` run only through the timelock itself — so shortening the delay is announced as far ahead as anything else. Queued operations expire after 14 days. Cancelling is immediate.

Until a timelock is wired, `timelock` is zero and the owner sets risk parameters directly, which is how a fresh deployment is configured at all. `setTimelock` closes that door, and `Deploy.s.sol` does it last, after every parameter is in place and immediately before ownership moves.

The signer set, the threshold and the delay: [docs/risk-parameters.md](../docs/risk-parameters.md).

## Emergency pause

A guardian, separate from the owner, can stop new risk-taking in the block it decides to. Only the owner can start it again. The asymmetry is the point: stopping is urgent and one signer's judgement is enough, restarting is a considered decision and belongs to the owner, which becomes the multisig. A guardian that could also unpause would be a second key with the owner's authority.

There is no timelock on pausing. A brake that waits is not a brake.

**Actions are bits, so one transaction can stop several.**

| Contract | Constant | Value | Stops |
| --- | --- | --- | --- |
| `SafixPool` | `PAUSE_DRAWS` | 1 | `draw` |
| `SafixPool` | `PAUSE_DEPOSITS` | 2 | `deposit` |
| `SafixPool` | `PAUSE_LIQUIDATIONS` | 4 | `liquidate` |
| `SafixPool` | `PAUSE_ALL` | 7 | all three, in one transaction |
| `PartnershipDesk` | `PAUSE_FUNDING` | 1 | `fund` |

`pool.pause(PAUSE_ALL)` is the single call that stops every way new risk enters the pool. Each bit is also independently pausable for the narrower cases — a compromised oracle wants liquidations stopped and nothing else.

**Nothing that lets a user out is pausable.** There is no switch for these, in any state:

`repay` · `closePosition` · `withdrawCollateral` · `claimGains` · `withdraw` · `lockCollateral` · on the desk, `reportReturn`, `claim` and `claimOperator`

`lockCollateral` is on that list because adding collateral cannot make a position worse; refusing it during an incident would only stop a borrower from rescuing themselves.

**Every pause and unpause is announced onchain.** `Paused(actions, pausedAfter, by)` and `Unpaused(...)` record which bits changed, the resulting mask, and who did it. `GuardianSet(guardian)` records appointments.

**The reason does not go onchain.** An incident is a paragraph, not a bitmask, and putting a half-formed diagnosis in calldata during an emergency is how a wrong one becomes permanent. What the chain records is that the brake was pulled, when, and by whom. The reason belongs in the incident log, written alongside it:

1. Guardian pulls the brake. Nothing waits on writing anything down.
2. Within the hour, an entry in the incident log: the transaction hash of the pause, the mask, what was observed, and who is handling it.
3. The entry is updated as the picture changes; the initial one is never rewritten.
4. Unpausing is an owner transaction and needs the log entry closed first, with what was found and what changed.

## Tests

```
forge test
```

164 tests: unit coverage for fees, LTV and freshness guards, liquidation gain and loss math, partnership settlement, passports, and Chainlink pricing; a partnership default suite covering the reporting deadline, recovery after a silent operator and the forfeited operator share; a passport operations suite covering the five checks, per-check expiry and withdrawal, and the gate; a timelock suite covering the delay and its boundary, expiry, cancellation, the floor on the delay, and the line between what waits and what does not; a bad debt suite covering gap-down liquidation, the reserve absorbing a shortfall, the reserve running dry with the remainder socialised, and the underwater dust write-off, each ending with a solvency assertion; a risk caps suite that tests every cap boundary from both sides and holds the accumulators to the positions they summarise; a repayment floor suite covering the repayment that cures an unhealthy position, the allowance and balance an escalation to the whole debt needs, and a floor raised under an open position; an emergency pause suite that drives every user-facing entry point through all eight combinations of the pool's pause bits and holds the role split and the exits open in each; a dedicated oracle safety suite covering sequencer down, the grace window and its boundary, out-of-band prices, sudden jumps between rounds, a reverting feed, per-asset staleness, and the exits staying open through all of it; plus a handler-based invariant suite that drives randomized action sequences and holds exact USDC conservation, compounded-deposit consistency, collateral solvency, and the P multiplier band.

## Deploy

Simulated end to end against the live Robinhood Chain testnet RPC: about 10.1M gas total, roughly 0.0002 ETH at the observed 0.02 gwei gas price. To broadcast for real, fund a key with testnet ETH and run:

```
PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast
```

The script deploys mock USDG and three mock collateral tokens, configures them, seeds the pool, deploys the registry and the desk, attests the deployer, and opens a first partnership. Afterwards `node ../scripts/wire-env.mjs testnet` writes the app env and the keeper config from the broadcast. For real stock tokens, configure each asset and wire its Chainlink feed with `setPriceFeed`; corporate actions arrive through the feed, so no extra handling is needed. On mainnet, <img src="../docs/assets/usdg.png" width="16" alt="USDG logo" /> USDG (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`) is the natural pool denomination.
