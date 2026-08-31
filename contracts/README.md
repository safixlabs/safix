# Safix contracts

Foundry workspace for the Safix protocol on Robinhood Chain.

## Contracts

- `SafixPool.sol`: the core. USDC-denominated stability pool with Liquity-style product-sum accounting (scale-aware, so precision survives arbitrarily heavy liquidation sequences), per-asset collateral configuration, zero-interest draws with a one-time origination fee added to debt, a redemption fee at position close, partial liquidation with a keeper incentive carved from seized collateral, Chainlink AggregatorV3 feeds per asset with manual price fallback and staleness guards, and an optional passport gate on draws.
- `PartnershipDesk.sol`: the profit and loss sharing track. Owner-created partnerships, pro-rata funding, capital to the operator on activation, onchain return reports, optional auditor-approved settlement, profit split at the agreed ratio, genuine losses on the capital.
- `PassportRegistry.sol`: attester-written five-check bitmask with optional expiry and revocation; `isEligible` is the single question integrated platforms ask.

## Tests

```
forge test
```

35 tests: unit coverage for fees, LTV and freshness guards, liquidation gain and loss math, partnership settlement, passports, and Chainlink pricing, plus a handler-based invariant suite that drives randomized action sequences and holds exact USDC conservation, compounded-deposit consistency, collateral solvency, and the P multiplier band.

## Deploy

Simulated end to end against the live Robinhood Chain testnet RPC: about 10.1M gas total, roughly 0.0002 ETH at the observed 0.02 gwei gas price. To broadcast for real, fund a key with testnet ETH and run:

```
PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast
```

The script deploys mock USDC and three mock collateral tokens, configures them, seeds the pool, deploys the registry and the desk, attests the deployer, and opens a first partnership. For real stock tokens, configure each asset and wire its Chainlink feed with `setPriceFeed`; corporate actions arrive through the feed, so no extra handling is needed. On mainnet, USDG (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`) is the natural pool denomination.
