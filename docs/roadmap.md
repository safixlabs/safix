# Safix roadmap

Written 6 September 2026. Dates are targets, not commitments, and every one of
them assumes the two human-gated items below are cleared in the first week.

## Where the work actually stands

| Surface | State |
| --- | --- |
| Contracts | Three written, 35 tests including four stateful invariants over 3,840 calls with no violation. Slither clean of anything actionable. **Live on Robinhood Chain Testnet** at `0xe438a058…`, with tBILL enabled at 80% max LTV, a 90% liquidation threshold and 251,955 USDG of seeded liquidity. Not verified on the explorer, so nobody outside the team can read the code behind the address. |
| Keeper | Runs, liquidates, proven against a local fork. No process supervision, no alerting, no funded operator key. |
| App | Every screen finished in both themes: borrow, pool, partnerships, passport, risk and terms. 29 end to end tests, a measured contrast pass, error reporting and a wallet picker. Serving demo data: the deployment exists, the hosted app is simply not pointed at it yet. |
| Docs | Published, current with the model, missing only the address table and the integration guide that a deployment produces. |

Nothing above is blocked on code. The testnet deployment happened; what is
missing is everything that turns a deployment into something other people can
use.

## The one human gate

**Which assets, and whose feeds.** Three tokenized assets to launch with, and
the Chainlink aggregator address for each. The testnet runs on a manual price
updater today, which is fine for a fork and unacceptable for anyone else's
money. Every risk parameter follows from that choice and none of them can be
settled before it.

Until that is answered, week 2 below does not start. Week 1 can.

## Utilities, in the order they arrive

### Week 1 · testnet alpha, closed
**Target: 15 September**

- Verify the deployed contracts on the explorer and publish the address table (safix#1, the deployment itself is done)
- Point the hosted app at the deployment, so the site stops serving demo data
- Sequencer uptime feed and per-asset sanity bounds on every price (safix#2)
- Emergency pause and a guardian who can use it (safix#3)

What works at the end of it: the whole app against real contracts, with the team
as the only users. Draw, repay, close, deposit, withdraw, liquidate.

### Week 2 · testnet beta, open
**Target: 22 September**

- Risk caps: per-asset debt and collateral ceilings, a global ceiling, a minimum
  position size (safix#4, safix#15)
- The keeper as a service: supervision, funded key, restart, backoff (safix#7)
- Monitoring and alerting, with someone on call (safix#8)
- Real assets onboarded with their own feeds (safix#9)

What works at the end of it: anyone with testnet funds can use Safix
unsupervised, and a position that falls through is liquidated whether or not
anybody is watching. **This is the beta.**

### Week 3 · the parts that are not code
**Target: 29 September**

- Passport attestation operations and an eligibility policy that says who
  attests what, and on what evidence (safix#10)
- Partnership desk operations, the auditor's mandate, and the agreement template
  behind a partnership (safix#11)
- Address table, integration guide, parameters, FAQ (safix-docs#1)
- Domain, cross-linking, social previews across all three surfaces
  (safix-docs#2)

### Week 4 to 5 · mainnet preparation
**Target: 10 October**

- Multisig ownership and a timelock on every risk parameter (safix#6)
- Bad debt policy and a reserve that absorbs it (safix#5)
- Event indexer, so history does not depend on a node's log retention
  (safix#12)
- Launch communications, the public repository decision, a security contact and
  a bug bounty (safix-docs#3)
- The mainnet runbook itself: treasury, final parameters, ownership handover
  (safix#13)

At the end of week 5 the code is frozen for audit.

### After the freeze · audit, then mainnet
**Not scheduled here**

An audit is three to five weeks of calendar for the review, plus whatever the
findings cost to fix. It is the one item deliberately outside this plan, and it
is the gate on mainnet rather than on the beta. Mainnet opens with caps low
enough that the first weeks are a live test rather than a launch.

## The honest risks in these dates

- **Asset onboarding is the schedule.** If the three assets picked have thin
  feeds or awkward decimals, week 2 becomes week 3. Nothing else on the list
  has that property.
- **Week 3 is legal work, not engineering.** The attestation policy and the
  partnership agreement need a lawyer's time, and that time is not ours to
  schedule. Start it in week 1 rather than week 3.
- **The keeper is the only always-on component.** Everything else fails
  visibly. A keeper that quietly stops is how a protocol takes bad debt, which
  is why monitoring lands in the same week it does.
