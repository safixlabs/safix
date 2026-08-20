# XYZ

Private credit network for tokenized stocks and real-world assets.

XYZ allows users to borrow stablecoins against their tokenized investments without selling them or publicly exposing their portfolio.

Documentation lives at [safixlabs/safix-docs](https://github.com/safixlabs/safix-docs).

## The problem

Blockchain activity is publicly visible. When users hold tokenized stocks or RWAs, anyone can inspect their wallets, balances, transactions, and financial positions.

These assets also have limited utility. Most holders can only hold or sell them, while borrowing against them remains difficult, fragmented, or limited to institutional platforms.

## The solution

XYZ allows users to lock tokenized stocks, bonds, funds, real estate, commodities, and other RWAs as collateral to borrow stablecoins.

The platform privately verifies that the collateral is real, valuable enough, eligible for use, and not already securing another loan.

## How it works

- Lenders deposit USDC into XYZ and earn interest.
- Borrowers lock approved tokenized assets as collateral and receive USDC from the lending pool. Once the loan and interest are repaid, the collateral is unlocked.
- If the collateral value falls below the required level, XYZ can liquidate part of it to protect lenders.

## Privacy layer

XYZ verifies important financial information without exposing the underlying data publicly. The network can confirm that a user:

- Owns enough approved collateral
- Meets identity and eligibility requirements
- Has an acceptable level of debt
- Is not reusing the same collateral
- Qualifies for the requested loan

The user's identity, exact holdings, wallet balances, and loan details remain confidential.

## Private collateral passport

XYZ creates a reusable private collateral passport that works across different wallets, blockchains, and lending platforms. Instead of revealing an entire portfolio, a user can provide proof that they have enough verified assets and meet the lender's requirements.

## Long-term vision

XYZ aims to become the private credit and collateral layer for onchain finance. Any wallet, lender, RWA platform, or financial application could use XYZ to privately answer one important question:

"Can this user safely and legally borrow against these assets?"

## Repository status

Protocol implementation has not started yet. This repository will host the core network code; see the docs repository for the full product specification.
