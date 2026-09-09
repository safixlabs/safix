# Passport attestation policy

Who attests what, on what evidence, for how long, and what happens when a fact changes.

Without this the registry is a data structure. The bitmask is the easy part; the hard part is that two reviewers looking at the same person must reach the same answer.

---

## The five checks

Each is a bit in `PassportRegistry`. Each expires on its own schedule, because the facts do not decay at the same rate.

### 1. `CHECK_IDENTITY` — the person is who they say they are

**Attested when:** a government-issued photo document has been verified as genuine and unexpired, the name on it matches the account, and a liveness check ties the person presenting it to the document.

**Evidence:** passport, national ID card, or driving licence, plus a liveness capture. A document alone is not enough — a photograph of someone else's passport passes document verification and fails this check.

**Not attested when:** the document is expired, the name does not match, the liveness check fails or was not performed, or the document is of a type the provider cannot verify.

**Expires:** when the document does, or **3 years** from attestation, whichever is sooner. Identity does not change; documents lapse and faces age.

### 2. `CHECK_JURISDICTION` — they are somewhere we may lend to

**Attested when:** the country of residence is on the permitted list below, evidenced by the identity document's issuing country **and** a second signal that agrees with it — a utility bill, a bank statement, or a tax identifier.

**Evidence:** two independent signals. One is where somebody lives on paper; two is where they live.

**Not attested when:** the two signals disagree, the country is not on the permitted list, or residence cannot be established at all. **A VPN-masked IP is not evidence of anything** and is neither grounds for attesting nor for refusing.

**Expires:** **1 year.** People move.

### 3. `CHECK_SANCTIONS` — they are not on a list

**Attested when:** screening against consolidated sanctions lists, politically-exposed-person databases and adverse media returns no match, or returns matches that have been reviewed and dismissed as false positives with the reasoning written down.

**Evidence:** a dated screening report naming the lists searched. "We checked" is not evidence; "we checked these lists on this date and here is the output" is.

**Not attested when:** there is an unresolved match, screening could not be completed, or the report is older than the current attestation cycle.

**Expires:** **90 days.** This is the shortest period of the five, and deliberately so: sanctions lists change weekly, and this is the check most likely to go from true to false without the subject doing anything.

### 4. `CHECK_COLLATERAL` — the collateral is theirs and only pledged here

**Attested when:** the wallet's holdings have been confirmed as genuinely held, and the subject has attested — in writing, in the agreement — that the same assets are not pledged against borrowing anywhere else.

**Evidence:** onchain balances at a stated block, plus the signed undertaking. **The protocol cannot see other platforms**, so this check is a representation by the borrower backed by a contractual consequence, not something verified independently. It is documented that way rather than dressed up as verification.

**Not attested when:** the undertaking is not signed, or there is evidence of the same assets pledged elsewhere.

**Expires:** **180 days.**

### 5. `CHECK_CAPACITY` — their existing debt leaves room

**Attested when:** disclosed obligations elsewhere, together with what they intend to borrow here, leave a total position the reviewer would extend credit against. There is no ratio in this document deliberately: the number depends on income stability and the asset class, and a ratio invites people to optimise for the ratio.

**Evidence:** disclosed obligations and a statement of intent, both dated.

**Not attested when:** disclosure is incomplete, or the total position leaves no margin.

**Expires:** **180 days.**

---

## What a reviewer does when it is borderline

**Do not attest.** A check is a claim that the thing is true, not that it is probably true. An unattested passport blocks a draw, which is recoverable in an afternoon. A wrongly attested one is a loan against a fact nobody verified.

**Two reviewers, one answer.** Any check dismissed as a false positive, any borderline call, and any exception is written into the review record with the reasoning. If a second reviewer could not reach the same conclusion from what is written down, the record is not finished.

---

## Jurisdiction

**Permitted at launch:** the United Kingdom, Switzerland, Singapore, the United Arab Emirates, and the EEA member states.

**Not permitted:** the United States and its territories, and any jurisdiction subject to comprehensive sanctions. The United States is excluded not for sanctions reasons but because lending against tokenized securities to US persons is a licensing question this protocol has not answered.

**What the registry does about an ineligible user: nothing.** There is no deny list, and non-attestation is not a record of refusal — an ineligible wallet is simply one the registry has never written to. The registry stores facts about people who passed, not judgements about people who did not. Keeping a list of refused wallets would create exactly the kind of onchain profile the passport exists to avoid.

If somebody becomes ineligible after being attested, the specific check is withdrawn with `revokeCheck`. Their remaining checks stand, because they remain true.

---

## The attestation path at launch

**Manual internal review, by two people, with a written record.**

Considered and set aside:

**An identity provider.** The right answer at volume, and the wrong first step. An automated pipeline encodes judgements that have not been made yet: it decides what "borderline" means before anyone has seen a borderline case. It is also a vendor relationship, a data processing agreement and a subprocessor before there is a single borrower. Revisit at roughly a hundred passports, when the edge cases are known rather than guessed.

**A proof system.** Where this goes — the "private collateral passport" is only meaningfully private when the attestation is a proof rather than a bit written by someone who saw the documents. Today it needs a circuit, a trusted setup or a proving service, and an issuer willing to sign credentials in a format that circuit accepts. None of those exist for this yet. The registry's shape does not preclude it: `isEligible` is the same question whether the bit behind it came from a reviewer or a proof, so the migration is an attester change rather than a redesign.

**Why manual, honestly:** at launch there will be tens of passports, not thousands. Two people reviewing carefully will be more accurate than a pipeline nobody has tuned, and every borderline case teaches what the automated version has to handle. The cost is that it does not scale, and that is a problem worth having later.

---

## Keys

**The attester key is not a protocol key.** It cannot pause, cannot change a parameter, cannot move a token. It can write attestations and nothing else, and `PassportRegistry` has no other authority to give it.

| Key | Holds | Never |
| --- | --- | --- |
| Attester | writing and withdrawing attestations | any pool function |
| Owner (multisig) | appointing and standing down attesters | attesting day to day |
| Guardian | the pause | attesting |
| Deployer | nothing, after handover | anything |

The owner *can* attest — `onlyAttester` admits the owner — and it should not. That path exists so a registry is usable before an attester is appointed, and using it routinely would put the multisig's key in the hands of whoever does reviews.

**One key per attester, and stand one down rather than sharing it.** `setAttester(address, false)` is instant and does not disturb attestations already written: a withdrawn attester's past work stands until it is individually reviewed. If a key is lost or suspected, stand it down first and review its recent attestations afterwards.

---

## Is the gate on at launch?

**Yes on mainnet. No on testnet.**

**On mainnet, `setPassportRegistry` is set before the first deposit.** Lending against tokenized securities to unverified wallets is not a risk position, it is a regulatory one, and it is not reversible after the fact. The cost is that borrowing needs a review first, which is the intended product rather than a compromise.

**On testnet it stays off,** so anyone with faucet funds can exercise the protocol without a review that would be theatre. `passportRegistry` is the zero address there and `draw` does not consult it.

Recorded here because it is the kind of decision that otherwise gets made by whoever runs the deploy script.

**The gate only guards drawing.** Depositing, withdrawing liquidity, locking and releasing collateral, repaying and closing are all open to any wallet. An ineligible wallet is never left holding collateral it cannot retrieve, and a revoked passport does not trap the position it was used to open. There are tests for both.

---

## Operating it

**First attestation** — one review, all five checks, `attest(subject, FULL_MASK, expiry)` with the earliest of the five expiries.

**Renewal** — `attestCheck(subject, check, expiry)`, one check at a time. Renewing the sanctions screen must not silently extend an identity check that nobody looked at. The registry keeps a separate expiry per check for this reason, and `checkMaskOf` reports the earliest, which is when the passport first stops being complete.

**A fact changed** — `revokeCheck(subject, check)`. The rest stand.

**They should not hold one at all** — `revoke(subject)`, which clears the mask and every per-check expiry.

**Nothing is deleted from the review record.** The onchain state changes; the offchain record gains an entry saying what changed, when, and why. The chain says a check was withdrawn; it never says why, and it should not.

## Review

The policy is reviewed **quarterly**, alongside the risk parameters, and immediately after:

- a jurisdiction changing its treatment of tokenized securities
- a sanctions regime change affecting a permitted jurisdiction
- the first attestation anyone disagrees with, which is the most informative event on this list
- reaching **100 passports**, which is the trigger to revisit the manual path
