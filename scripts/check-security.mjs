// Verifies the security policy is internally consistent and reports, by name,
// every decision still outstanding. It fails on a policy that contradicts
// itself; it does not fail on a decision nobody has taken yet, because that is
// the honest state of the project and hiding it would be the wrong outcome.
//
//   npm run check:security

import { existsSync, readFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const config = JSON.parse(readFileSync(join(root, "security.config.json"), "utf8"))
const { contact, disclosure, bounty, support, openSource } = config

const problems = []
const outstanding = []

if (!existsSync(join(root, "SECURITY.md"))) {
  problems.push("SECURITY.md is missing; run npm run build:security")
} else {
  const published = readFileSync(join(root, "SECURITY.md"), "utf8")
  const claimsEmail = /Email \*\*([^*]+)\*\*/.exec(published)?.[1]
  if (claimsEmail && claimsEmail !== contact.email) {
    problems.push(`SECURITY.md publishes ${claimsEmail} but the configuration says ${contact.email ?? "no address"}; run npm run build:security`)
  }
  if (!claimsEmail && contact.email) {
    problems.push("an address is configured but SECURITY.md does not publish it; run npm run build:security")
  }
  const claimsBounty = published.includes("| Severity | Reward |")
  if (claimsBounty !== bounty.live) {
    problems.push(`SECURITY.md ${claimsBounty ? "publishes" : "omits"} a reward table but the bounty is ${bounty.live ? "live" : "not live"}; run npm run build:security`)
  }
}

// A channel has to be exactly one thing, and a live bounty has to be payable.
if (contact.email && contact.githubAdvisories) {
  problems.push("two reporting channels are configured; publish one so a reporter has one place to go")
}
if (bounty.live) {
  if (!contact.email && !contact.githubAdvisories) {
    problems.push("the bounty is live but there is nowhere to report to")
  }
  if (!bounty.currency) problems.push("the bounty is live but no currency is set")
  for (const [severity, amount] of Object.entries(bounty.rewards)) {
    if (amount === null) problems.push(`the bounty is live but the ${severity} reward is unset`)
  }
}
if (bounty.inScope.length === 0) problems.push("the bounty has no scope")
if (bounty.outOfScope.length === 0) problems.push("the bounty says nothing about what is out of scope")

const fix = disclosure.fixTargetDays
for (const [severity, days] of Object.entries(fix)) {
  if (days > disclosure.maximumEmbargoDays) {
    problems.push(`the ${severity} fix target of ${days} days is longer than the ${disclosure.maximumEmbargoDays} day embargo`)
  }
}
if (fix.critical > fix.high || fix.high > fix.medium || fix.medium > fix.low) {
  problems.push("the fix targets are not ordered by severity")
}

if (support.channel && !support.url && support.channel !== "email") {
  problems.push(`the support channel is ${support.channel} but no url is published for it`)
}
if (support.channel === "email" && !support.url) {
  problems.push("the support channel is email but no address is published")
}
if (support.channel && support.responders.length === 0) {
  problems.push("a support channel is published with nobody named as answering it")
}

// Decisions nobody has taken. These are reported, not failed.
if (!contact.email && !contact.githubAdvisories) {
  outstanding.push("no vulnerability reporting channel is published, so nobody outside the project can report one")
}
if (!bounty.live) outstanding.push("the bug bounty has no reward table, so it is scoped but not funded")
if (!support.channel) outstanding.push("no support path is published, so a user with a problem has nowhere to go")
if (!openSource.decided) {
  const undecided = Object.entries(openSource.repositories)
    .filter(([, entry]) => entry.opensAt === null)
    .map(([name]) => name)
  outstanding.push(`the public repository decision is open for ${undecided.join(", ")} (due ${openSource.decisionDue})`)
}

if (problems.length > 0) {
  console.error(`check-security: ${problems.length} problem(s)`)
  for (const problem of problems) console.error(`  - ${problem}`)
  process.exit(1)
}

console.log(`check-security: policy is consistent, ${outstanding.length} decision(s) outstanding`)
for (const item of outstanding) console.log(`  pending: ${item}`)
