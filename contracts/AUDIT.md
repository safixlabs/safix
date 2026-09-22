# Notes for an audit

What the contracts are, what is in scope, what the static analyser reports and why
each report was left as it is. Written so a reviewer starts from what is known
rather than rediscovering it.

## Scope

| Contract | Lines | What it is |
| --- | --- | --- |
| `SafixPool.sol` | 677 | The protocol. Collateral, zero-interest credit, the stability pool, liquidation, and the oracle handling in front of all of it. |
| `PartnershipDesk.sol` | 236 | Profit-and-loss financing, separate from the pool and with no claim on it. |
| `PassportRegistry.sol` | 104 | Who has been verified for what, written by attesters and read by the pool. |
| `SafixTimelock.sol` | 76 | The delay every parameter change passes through. |
| `Guardable.sol` | 25 | The guardian's pause. |

`MockERC20.sol` and `MockAggregatorV3.sol` are test doubles. They are deployed on
testnet and never on mainnet, and are out of scope.

## The model, in one paragraph

A borrower locks a tokenized asset and draws a stablecoin against it. There is no
interest: a fee is charged at the draw and another on principal as it is repaid,
so the debt recorded at the draw is the debt owed however long the position is
held. Providers deposit into a stability pool that absorbs liquidations, and are
paid in the collateral those liquidations seize, at a discount to its price. The
protocol takes nothing from a liquidation.

## Trust model

**The owner** pauses, unpauses, collects protocol fees, appoints the guardian and
the price updater, and absorbs dust bad debt. It cannot change a parameter, move
a deposit, or touch collateral.

**The timelock** holds every parameter: fees, ratios, caps, guards, feeds, the
auditor, asset retirement. Each change waits its delay in public and expires if
nobody executes it.

**The guardian** can pause and cannot unpause. A guardian that is compromised can
stop the protocol and cannot drain it.

**No role can take a provider's deposit or a borrower's collateral.** Withdrawal,
repayment and closing a position are not pausable, so no role can trap anyone
inside.

## What is deliberately absent

**No sequencer uptime feed is wired.** Chainlink has not published one for this
chain and says it is no longer adding them. `setSequencerUptimeFeed` and the
grace period exist and are tested; the address is unset because there is nothing
to set it to. `scripts/check-sequencer-feed.mjs` asks again every week.

**No upgradeability.** The contracts are not proxied. A change means a new
deployment and a migration people consent to.

**Asset retirement stops new exposure and nothing else.** A retired asset still
prices, so positions against it stay liquidatable. Clearing `enabled` instead
would remove the price and leave bad debt nobody could clear.

## Static analysis

Slither 0.11.6, all detectors, `lib|test|script|Mock` filtered.

**No high-severity findings.** The medium ones are below with the reason each was
left. CI fails the build on any high finding, so a new one cannot land quietly.

### `divide-before-multiply`, 7

Two different things wear this label here.

Four are `value = (collateral * price) / 1e30` followed by a ratio applied to
`value`. The division truncates below one unit of the stablecoin, and it
truncates downward, which lowers borrowing capacity and raises the liquidation
bar by at most that unit. Both directions favour the pool.

Three are the product-sum accounting in `_distributeToProviders`, which is
Liquity's algorithm. The division precedes the scale multiplication because the
scale rollover is the mechanism that recovers the precision the division loses.
Reordering it would break the thing it is there for.

### `incorrect-equality`, 11

Every one is an enum comparison (`status == PriceStatus.Stale`) or a zero check on
a mapping. The detector looks for equality against balances and timestamps.

### `reentrancy-no-eth`, 1

`claimGains` loops over assets, and the state write for one iteration follows the
transfer of the previous one. Within each iteration the balance is zeroed before
its own transfer, and the function carries `nonReentrant`. The caller chooses the
asset list, so a hostile token in it can only reach the caller's own claim.

### `unused-return`, 3

The Chainlink reads take `roundId`, `answer` and `updatedAt` and ignore
`startedAt` and `answeredInRound`. Staleness is judged on `updatedAt` against each
asset's own `maxPriceAge`, which is Chainlink's current guidance;
`answeredInRound` is deprecated and equal to `roundId` on OCR feeds.

## Tests

200 tests across 19 suites, including 7 stateful invariants over 64 runs of 3,840
calls each. Line coverage is 100% on `Guardable`, `PartnershipDesk` and
`PassportRegistry`, 99.8% on `SafixPool`, 97.9% on `SafixTimelock`.

Two lines are unreached and both are unreachable rather than untested.
`SafixPool`'s final `revert("asset off")` is the default arm of a status switch
whose every other arm returns first, and no configured asset can reach it because
`enabled` is never cleared. `SafixTimelock.operationId` is a pure helper the
contract calls internally and nothing calls from outside.

```
cd contracts && forge test
cd contracts && forge coverage --report summary
```

## Where to start

`SafixPool.sol`, and within it `_distributeToProviders`. It is the whole of the
product-sum accounting, it is the only place a provider's balance changes as a
result of somebody else's liquidation, and it is the arithmetic most worth a
second reader.
