# Security policy

This policy covers **safixlabs/safix**: protocol contracts, the Foundry test suite, the liquidation keeper and the information memorandum.

Safix holds other people's collateral and other people's deposits, and the contracts have not been
through an independent security audit. If you find something, we want to hear about it before
anybody loses money.

## Reporting a vulnerability

**There is no published reporting channel yet.** This repository is private and no security
address has been announced, so somebody outside the project currently has no way to report a
vulnerability, and no responsible way to publish one either.

Opening that channel is tracked in [https://github.com/safixlabs/safix-docs/issues/3](https://github.com/safixlabs/safix-docs/issues/3), and it has to be
open before anything reaches mainnet, and the protocol is already live on testnet. Until then:
please do not disclose a finding
in a public issue. Wait for the channel, or reach a maintainer privately through whoever gave you
access to this repository.

Please do not open a public issue, post it publicly, or test against funds that are not yours.

## What happens next

- **Acknowledgement** within 48 hours.
- **Triage and a severity** within 5 days, with the reasoning.
- **A fix** targeted at 7 days for critical, 14 for high, 30 for medium, 90 for low.
- **Publication** within 30 days of the fix shipping, crediting you unless you would rather we did not.
- **An embargo of no more than 90 days.** If we cannot fix it in that time we will say so and agree a date with you rather than let it sit.

## Safe harbour

We will not pursue or support legal action against anyone who reports in good faith under this
policy, stays inside the scope below, does not access, modify or destroy anyone else's data, and
gives us a reasonable chance to fix the problem before telling anyone else.

If a third party brings action against you for research that followed this policy, we will make it
known that it did.

## In scope

- SafixPool: loss of funds, theft of collateral or deposits, minting debt without collateral, breaking the loan-to-value or liquidation-threshold checks
- SafixPool: accounting errors in the product-sum stability pool that misprice a provider's stake or gains
- SafixPool: price handling, including feed staleness, decimal scaling and the manual price path
- PassportRegistry: forging eligibility, bypassing the draw gate, or writing an attestation without being an attester
- PartnershipDesk: taking another funder's payout, claiming twice, or settling without the auditor when one is configured
- Any owner-only function reachable by an account that is not the owner
- The keeper: a path that lets a third party move funds through it, or that makes it liquidate a healthy position
- The application: a flow that makes a user sign a transaction other than the one shown, or that leaks passport data

## Out of scope

- Anything requiring the owner key, the deployer key or an attester key to be compromised first
- Price movements, liquidations and losses that follow from the documented parameters working as designed
- Denial of service against a public RPC endpoint, or gas-cost griefing without loss of funds
- Findings that only apply to a chain, token or configuration Safix does not deploy against
- Automated scanner output with no demonstrated exploit path
- Social engineering, phishing, or physical attacks against anyone working on Safix
- Missing best practices with no exploit, such as a lack of events or a public function that could be external

## Rewards

**The bug bounty is not live.** The protocol is deployed to Robinhood Chain Testnet, where the
tokens are test tokens and nothing at risk is worth anything, and no reward amounts have been
signed off for mainnet. Publishing a table now would be a promise with no money behind it.

The scope and the rules above are the programme; the reward table is the only part still missing,
and it lands before the first mainnet transaction. Reports sent before then are still wanted,
still triaged on the timelines above, and still credited.

## About this repository

The code here declares **AGPL-3.0-only** (SPDX headers on every Solidity file). Whether it becomes public, and when, is not decided. That decision is due before the first mainnet transaction and is tracked in [https://github.com/safixlabs/safix-docs/issues/3](https://github.com/safixlabs/safix-docs/issues/3).

---

Generated from `security.config.json` by `scripts/build-security.mjs`. Edit the configuration, not
this file.
