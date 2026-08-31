# Safix

Private credit network for tokenized stocks and real-world assets.

Safix allows users to borrow stablecoins against their tokenized investments without selling them or publicly exposing their portfolio.

Documentation lives at [safixlabs/safix-docs](https://github.com/safixlabs/safix-docs).

## The problem

Blockchain activity is publicly visible. When users hold tokenized stocks or RWAs, anyone can inspect their wallets, balances, transactions, and financial positions.

These assets also have limited utility. Most holders can only hold or sell them, while borrowing against them remains difficult, fragmented, or limited to institutional platforms.

## The solution

Safix allows users to lock tokenized stocks, bonds, funds, real estate, commodities, and other RWAs as collateral to borrow stablecoins.

The platform privately verifies that the collateral is real, valuable enough, eligible for use, and not already securing another loan.

## How it works

- Liquidity providers deposit USDC into a shared stability pool.
- Borrowers lock approved tokenized assets as collateral and draw USDC at zero interest, paying a fixed one-time origination fee instead. Once the drawn amount is repaid, the collateral is unlocked.
- If the collateral value falls below the required level, Safix liquidates part of it. Liquidated collateral flows to the stability pool at a discount, which is where liquidity provider returns come from, together with protocol token rewards.

## Financing model

Safix charges for events, not for time. There is no time-based interest anywhere in the network.

- Zero-interest credit line, following the peer-to-pool model pioneered by Liquity: a one-time origination fee (for example 0.5%) when funds are drawn and a fixed redemption fee when the position is closed. Debt never grows over time.
- Profit and loss sharing: for financing tied to a business or a productive asset, the pool provides capital as a partner instead of a creditor. Profit is split at a pre-agreed ratio (for example 60/40). Genuine losses without misconduct or negligence fall on the capital.

## Privacy layer

Safix verifies important financial information without exposing the underlying data publicly. The network can confirm that a user:

- Owns enough approved collateral
- Meets identity and eligibility requirements
- Has an acceptable level of debt
- Is not reusing the same collateral
- Qualifies for the requested loan

The user's identity, exact holdings, wallet balances, and loan details remain confidential.

## Private collateral passport

Safix creates a reusable private collateral passport that works across different wallets, blockchains, and lending platforms. Instead of revealing an entire portfolio, a user can provide proof that they have enough verified assets and meet the lender's requirements.

## Long-term vision

Safix aims to become the private credit and collateral layer for onchain finance. Any wallet, lender, RWA platform, or financial application could use Safix to privately answer one important question:

"Can this user safely and legally borrow against these assets?"

## Repository status

The protocol core is implemented and tested.

- `contracts/`: Foundry workspace with SafixPool (stability pool, zero-interest credit line, Chainlink feed pricing, scale-aware loss accounting, liquidation incentive, passport gate), PartnershipDesk (profit and loss sharing with auditor-approved settlement), and PassportRegistry. 35 tests including stateful invariants over randomized action sequences.
- `keeper/`: viem worker that discovers positions from events, pushes prices for feedless assets, and liquidates unhealthy positions automatically.
- `docs/`: the information memorandum (markdown, HTML, PDF).

App: [safix-app.vercel.app](https://safix-app.vercel.app) · Documentation: [safix-docs.vercel.app](https://safix-docs.vercel.app)

## Testnet deployment

Fund a key with Robinhood Chain testnet ETH, then:

```
cd contracts
PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast
```

Then wire the app and the keeper straight from the broadcast:

```
node scripts/wire-env.mjs testnet
```

That writes the app's `.env.local` and `keeper/config.json` from the deployed addresses. For real stock tokens, wire their Chainlink feeds with `setPriceFeed`.
