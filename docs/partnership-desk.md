# Partnership desk operations

A partnership is a legal relationship before it is a contract call. The desk implements the mechanics; this is the half that makes them mean something.

The distinction from the pool matters: the pool lends at zero interest against collateral it holds. The desk **puts capital into a business** and shares what the business earns. Nothing secures it. A funder can lose the lot, and the agreement says so in those words.

---

## The agreement

Template for the first partnerships. Terms in `[brackets]` are per-partnership; everything else is the same each time, and a change to it is a change to this document rather than to one agreement.

### 1. Parties and capital

The Operator is `[legal entity, registration number, jurisdiction]`. Funders are the addresses recorded against partnership `[id]` in `PartnershipDesk` at `[address]`.

The Operator receives `[funded amount]` USDG on activation, to be applied to `[stated purpose]` and nothing else.

If the partnership has not been activated by `[funding deadline]`, anyone may cancel it, and each Funder recovers their contribution in full. The Operator receives nothing, and nobody owes anybody anything further.

### 2. Profit split

Profit is what the Operator returns above the capital they received. It is split **`[100 − share]`% to Funders, `[share]`% to the Operator**, computed onchain by `operatorShareOf` and paid by `claim` and `claimOperator`.

Profit is measured on the whole partnership at settlement, not per period. There is no interest, no preferred return and no hurdle: the Operator earns a share of a gain or nothing.

### 3. Loss

**Genuine losses fall on the capital.** If the venture returns less than it received, Funders bear the shortfall pro rata and the Operator owes nothing beyond what they have returned. That is the deal: the Operator's downside is their time and their share of a gain that did not happen.

This is the clause that separates a partnership from a loan, and no side agreement may reverse it. Any instrument that guarantees the capital is a loan wearing a partnership's name, and belongs on the pool, not here.

### 4. Misconduct and negligence

Losses arising from **misconduct or negligence do not fall on the capital.** The Operator is liable for the full amount, and this survives settlement.

Misconduct is: applying capital to a purpose other than the stated one; misstating a return report; failing to disclose a conflict; or any act that would be dishonest to a reasonable person in the Operator's position.

Negligence is failing to exercise the care a competent operator in the same business would exercise. It is not being wrong about the market, and it is not a venture that failed for reasons visible to everyone at the time.

**The distinction is the whole clause,** and the auditor's report is the primary evidence of which side of it a loss falls on.

### 5. Reporting

The Operator reports **monthly, by the tenth**, whether or not there is anything to return. A period with nothing to report is reported as such: silence is not a report, and the deadline is not extended by there being no news.

Each report carries: capital deployed to date and against what; revenue and costs for the period; anything returned to the desk and the transaction hash; and any event that changes what was disclosed at the outset.

Reports go to the Funders and the Auditor in the same delivery. A report to one and not the other has not been made.

### 6. Settlement

At the end of `[term]`, or earlier by agreement, the Operator returns the capital and any profit via `reportReturn`. The Auditor reviews and calls `approveSettlement`; the Owner then calls `settle`, and Funders and the Operator claim their shares.

**The reporting deadline is `[date]`, onchain.** Past it, without a settlement, anyone may call `declareDefault`. See below.

### 7. Default

If the Operator does not settle by the reporting deadline, the partnership is declared in default. Whatever has been returned is distributed to Funders pro rata, **and the Operator's profit share is forfeit** — a partnership that had to be declared in default did not earn one.

Default does not extinguish the Operator's obligation to return the capital, and `reportReturn` stays open afterwards: an Operator making good after the deadline is better for Funders than one who stops because the door closed.

Default is not itself misconduct. It is a missed date, and the liability question is decided under clause 4 on the facts.

### 8. Disputes

1. **Raise it in writing** with the Operator and the Auditor. Most disputes are a disagreement about a number and end here.
2. **The Auditor's determination**, within 14 days, on any question of fact — what was returned, what was spent, what a report said. Binding on facts, not on liability.
3. **Arbitration** under `[rules]`, seated in `[seat]`, for anything remaining, including whether a loss falls under clause 3 or clause 4.

The onchain state is evidence of what was transferred and when. It is not evidence of why, and no clause here treats it as such.

### 9. Signature

Signed by the Operator and countersigned by Safix before the partnership is created onchain. **The onchain partnership is created after the agreement is signed, never before** — capital must not be fundable against terms nobody has agreed to.

---

## The auditor

**Mandate.** The Auditor verifies what the Operator reports before capital is settled. Specifically: that reported returns match what arrived at the desk; that reported costs are supported by records; that capital was applied to the stated purpose; and, where a loss is claimed as genuine, whether the facts support that or point to clause 4.

They call `approveSettlement`, and that is their only onchain power. They cannot create, fund, activate or settle a partnership, and they cannot move a token. Like anyone, they can cancel a partnership the Owner left unactivated past its funding deadline; that is a Funder's exit, not an Auditor's power. **`settle` requires their approval whenever an auditor is set** — the Owner cannot settle around them.

**Independence.** The Auditor must not be a Funder in the partnership they audit, hold any interest in the Operator, be compensated on the outcome, or be appointed by the Operator. Appointment is by the Owner through the timelock, so it is visible in advance and cannot be changed to suit a settlement in progress.

**For the first partnerships the Auditor is an external accountant** engaged directly by Safix, retained by the hour rather than by outcome, and named in each agreement. Not a team member: the person checking the numbers must not be the person who wants the partnership to have worked.

**If the Auditor cannot form a view**, they say so rather than approving. A settlement that cannot be audited does not settle, and the dispute path handles the remainder.

**Standing one down** is `setAuditor` through the timelock, which takes 48 hours and is publicly visible while it waits — appropriate for a change that could otherwise be made to clear a settlement.

---

## Runbook

### Create

1. Agreement signed by both parties. **Nothing onchain before this.**
2. Confirm the Auditor is set: `desk.auditor()`.
3. `createPartnership(operator, operatorShareBps, fundingGoal, fundingDeadline, reportingDeadline)` — Owner only.
   - `fundingDeadline`: how long funding stays open, typically 14–30 days.
   - `reportingDeadline`: the term plus a settlement window, typically the term plus 30 days. It must be after the funding deadline, and the contract enforces that.
4. Record the id, both deadlines and the agreement reference in the partnership log.

### Fund

Funders call `fund(id, amount)` until the goal or the deadline. Contributions are recorded per address and are what payouts are computed from.

Funding can be stopped instantly by the guardian: `pause(PAUSE_FUNDING)` needs no timelock and no second signature. Use it if something about the Operator changes while funding is open.

### Activate

`activate(id)` sends the funded capital to the Operator. **This is the irreversible step** — after it, recovery depends on the Operator and on the deadline, not on the desk.

Before calling it: funding is what was expected, nothing has changed about the Operator since signature, and the reporting deadline is still appropriate for the term.

`cancel(id)` before activation returns every contribution in full, and remains available while the desk is paused.

**Activate by the funding deadline.** Past it, a partnership that was never activated can be cancelled by **anyone** with `cancelUnactivated(id)`, and each Funder then claims their contribution back in full. It is `declareDefault` one step earlier: capital that was never put to work must not be stranded by an Owner who does nothing. The Owner keeps the choice — `activate` still works after the deadline if nobody has cancelled — but from that moment a Funder can decline to wait, and whichever transaction lands first decides. Either way the Funders have a way out: a refund, or the reporting deadline. It stays open while the desk is paused.

### Report

Monthly, by the tenth, to Funders and Auditor together. Returns arrive via `reportReturn(id, amount)`, which moves the stable and is the record of what came back.

**A missed report is an escalation, not an administrative matter.** Chase within 3 days; if nothing by 10 days, notify Funders that the partnership is off schedule. A silent operator is the situation the deadline exists for.

### Audit and settle

1. Operator returns capital and profit via `reportReturn`.
2. Auditor reviews against the mandate above and calls `approveSettlement(id)`.
3. Owner calls `settle(id)`.
4. Funders call `claim(id)`; the Operator calls `claimOperator(id)`.

### Default

Past the reporting deadline with no settlement, **anyone** may call `declareDefault(id)` — deliberately not Owner-only, because a funder's recovery must not depend on the team being available.

After it: Funders claim their pro-rata share of whatever was returned, the Operator's share is forfeit, and the obligation to return capital survives. Pursue it under the agreement; the onchain state is the evidence of what did and did not arrive.

---

## The first partnership

**Not yet confirmed.** No candidate has been agreed, so there is no operator, no term and no split to record here.

What is settled is everything a candidate would be assessed against: the template above, the auditor mandate, the reporting cadence and the default path. When a candidate is agreed, this section records the operator's legal entity, the stated purpose, the split, the funding goal, both deadlines, the auditor engaged, and the signature date.

**The desk is not opened to funders before that.** A partnership with terms but no counterparty is a form; a partnership with a counterparty but no signed terms is the thing clause 9 exists to prevent.

## Review

This document is reviewed when a partnership defaults, when the auditor cannot form a view on a settlement, when a dispute reaches arbitration, and otherwise annually. The first three are the ones that will actually teach something.
