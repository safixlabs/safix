# Safix contracts

Foundry workspace for the Safix protocol on Robinhood Chain.

## Contracts

- `SafixPool.sol`: the core. USDC-denominated stability pool with Liquity-style product-sum accounting (scale-aware, so precision survives arbitrarily heavy liquidation sequences), per-asset collateral configuration, zero-interest draws with a one-time origination fee added to debt, a redemption fee at position close, partial liquidation with a keeper incentive carved from seized collateral, Chainlink AggregatorV3 feeds per asset with manual price fallback, the oracle safety layer described below, and an optional passport gate on draws.
- `PartnershipDesk.sol`: the profit and loss sharing track. Owner-created partnerships, pro-rata funding, capital to the operator on activation, onchain return reports, optional auditor-approved settlement, profit split at the agreed ratio, genuine losses on the capital.
- `PassportRegistry.sol`: attester-written five-check bitmask with optional expiry and revocation; `isEligible` is the single question integrated platforms ask.

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

## Tests

```
forge test
```

58 tests: unit coverage for fees, LTV and freshness guards, liquidation gain and loss math, partnership settlement, passports, and Chainlink pricing; a dedicated oracle safety suite covering sequencer down, the grace window and its boundary, out-of-band prices, sudden jumps between rounds, a reverting feed, per-asset staleness, and the exits staying open through all of it; plus a handler-based invariant suite that drives randomized action sequences and holds exact USDC conservation, compounded-deposit consistency, collateral solvency, and the P multiplier band.

## Deploy

Simulated end to end against the live Robinhood Chain testnet RPC: about 10.1M gas total, roughly 0.0002 ETH at the observed 0.02 gwei gas price. To broadcast for real, fund a key with testnet ETH and run:

```
PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast
```

The script deploys mock USDG and three mock collateral tokens, configures them, seeds the pool, deploys the registry and the desk, attests the deployer, and opens a first partnership. Afterwards `node ../scripts/wire-env.mjs testnet` writes the app env and the keeper config from the broadcast. For real stock tokens, configure each asset and wire its Chainlink feed with `setPriceFeed`; corporate actions arrive through the feed, so no extra handling is needed. On mainnet, <img src="../docs/assets/usdg.png" width="16" alt="USDG logo" /> USDG (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`) is the natural pool denomination.
