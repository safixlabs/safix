# Safix: unlock capital, keep ownership

Information memorandum, draft v1.2, September 2026

Tokenization solved ownership. It did not solve two things that follow from it: everything you own onchain is public, and almost nothing you own onchain can be borrowed against. Safix is a private credit layer that fixes both. Lock tokenized real-world assets as collateral, draw USDG at zero interest, and prove you qualify without showing anyone your portfolio.

## The problem

Tokenized real-world assets crossed 31 billion dollars on public blockchains in July 2026, up more than 400 percent since early 2025, held by nearly a million wallets across 167 platforms. Six categories are past the billion mark: private credit, commodities, treasuries, corporate bonds, non-US government debt, and institutional funds. The rails work. The assets exist.

Then they sit there. For most holders, a tokenized stock or bond has exactly two functions: hold it or sell it. Borrowing against it remains fragmented, institutional, or impossible, and onchain private credit is still a single-digit-billions market by distributed value. The largest asset class coming onchain has no working credit layer underneath it.

The second problem compounds the first. Blockchains are public by default. A wallet that holds tokenized stocks is a brokerage statement anyone can read: balances, positions, transaction history, and from the moment you borrow, your debts. No serious investor runs their finances in a window display, and no serious credit market can be built inside one.

## What Safix is

Safix is a private credit layer for tokenized assets. Four parts make it work:

- Collateral risk checks. Before any loan, the protocol privately verifies that the collateral is real, valuable enough, eligible, and not already pledged elsewhere, and that the borrower's existing debt is acceptable.
- Zero-interest credit. Borrowers draw USDG against locked collateral for a fixed one-time fee. Debt never grows with time. The full cost is known on day one.
- Reusable credit passports. A portable, private proof of borrowing power that works across wallets, chains, and lending platforms. Counterparties see eligibility signals only. Holdings disclosed: zero percent.
- Collateral control plane. One view of collateral health, available credit, and every attestation in force, so a borrower always knows where they stand.

## How the money works

There is no time-based interest anywhere in the network. Safix charges for events, not for time.

The credit line follows the peer-to-pool model pioneered by Liquity. Liquidity providers fund a stability pool with USDG. Borrowers lock collateral and draw from it, paying a one-time origination fee, then a fixed redemption fee when the position closes. If collateral value falls below the required level, part of it is liquidated: the pool absorbs the debt and receives the collateral at a discount. That flow, together with protocol rewards, is where provider returns come from. Providers earn from real events in the network, not from the passage of time.

For financing tied to a business or a productive asset, Safix replaces the creditor relationship with a partnership. The pool provides capital, the financed party operates it, and profit is split at a pre-agreed ratio. Genuine losses without misconduct fall on the capital. Whoever funds a venture carries its risk, which is how credit stays honest.

Revenue comes from origination fees, redemption fees, private verification fees, liquidation fees, a protocol share of partnership profits, and integrations: RWA issuers who want their assets to be borrowable, and lending platforms that want verified collateral without building verification.

## The privacy layer

Safix answers questions without revealing data. A counterparty can confirm five things about a user: they own enough approved collateral, they meet identity and eligibility requirements, their existing debt is acceptable, the same collateral is not pledged elsewhere, and they qualify for the requested loan. That is all a lender actually needs, and it is all they get. Identity, exact holdings, wallet balances, and loan details stay confidential.

The credit passport makes this reusable. Verified once, a borrower can present proof to any integrated platform without repeating the process and without a lender ever seeing the portfolio behind the proof.

## Why now

Three curves crossed. The issuance layer matured: platforms like Securitize, Centrifuge, Backed, and Ondo turned tokenized treasuries, funds, and equities into a real market. Stablecoin credit demand proved itself onchain, but at rates and disclosure levels that keep serious collateral away. And proof systems became practical enough to verify claims about assets without publishing the assets themselves. The first two created the market. The third makes Safix buildable now and not five years ago.

## The chain

Safix builds on Robinhood Chain, the Arbitrum Orbit rollup where tokenized equities are issued. Stock Tokens there are standard, unrestricted ERC-20s, and every one ships with a dedicated Chainlink price feed. That means Safix can accept them as collateral without issuer permission and price them without building an oracle. The pool denominates in whichever dollar stablecoin has the deepest local liquidity.

## What exists today

Onchain lending bluechips price everything in public and mostly against crypto-native collateral. RWA lending desks are institutional, slow, and paperwork-bound. Privacy tools hide transfers but answer no questions, which is exactly backwards for credit, where the counterparty must learn something. Safix sits in the gap: it answers the credit questions and hides everything else. The defensible part is the passport. Every verification strengthens a reusable identity that borrowers will not want to rebuild elsewhere, and every integrated platform makes it more useful to hold one.

## Where we are

Safix is past the paper stage and past the devnet. The protocol core is implemented and tested: a stability pool with Liquity-style loss accounting, zero-interest draws, partnership financing, and a passport-gated credit line, 156 tests green including five stateful invariants driving randomised sequences of actions. All three contracts are deployed to Robinhood Chain Testnet and readable there, seeded with 251,955 USDG of stability pool liquidity, with the addresses published in the documentation and every parameter read back off the chain rather than described. The pool reads the per-asset Chainlink feeds Robinhood Chain ships for every stock token, an off-chain keeper liquidates unhealthy positions automatically, and the full lifecycle has been exercised end to end: draw, price drop, automated liquidation, provider gains, partnership settlement. The app and the documentation are live. The immediate work is narrower than ever: verify the contracts on the explorer, wire the real feeds, and put the first tokenized treasuries behind the pool.

## Risks, honestly

- Tokenized collateral is only as strong as its legal wrapper. If offchain enforcement fails, onchain verification does not save you. Issuer selection is underwriting.
- Zero-interest economics depend on event flow. In calm markets, liquidation gains thin out and provider yield leans on fees and rewards. Fee routing to the pool is an open design decision, deliberately.
- The privacy layer must satisfy regulators and users at the same time. Proving eligibility without disclosure is a narrow path, and it is the entire product.
- Partnership financing needs honest profit measurement. Attesting business outcomes is hard, and the attestation layer must carry that weight.
- Incumbents could move: lending protocols could add RWA privacy, issuers could build credit in-house. The passport has to become the standard before that happens.

## Worst case, best case

Worst case: a disciplined zero-interest lending pool for tokenized assets, serving borrowers who value not being watched, earning real fees on real collateral.

Best case: the credit passport becomes the layer every wallet, lender, and RWA platform uses to answer one question they all share: can this user safely and legally borrow against these assets?

## Closing

Tokenization gave assets a new home. Safix gives them work to do. Owning something onchain should not mean broadcasting it, and unlocking its value should not mean selling it. Unlock capital. Keep ownership.

Note: This memorandum is a working draft provided for information purposes only. It is not an offer of securities, not a solicitation of investment, and not financial advice. Market figures are from rwa.xyz as of July 2026.
