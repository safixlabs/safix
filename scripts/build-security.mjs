// Writes SECURITY.md from security.config.json.
//
// The policy is the same in all three repositories and is generated rather than
// copied, so a timeline or a scope line cannot say one thing here and another
// thing next door. The generator will not invent a reporting channel or a
// reward: where the configuration is null the file says plainly that the
// decision has not been taken, because a security policy that points at an
// address nobody reads is worse than one that admits there is none yet.
//
//   npm run build:security

import { execFileSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const config = JSON.parse(readFileSync(join(root, "security.config.json"), "utf8"))

const fail = message => {
  console.error(`build-security: ${message}`)
  process.exit(1)
}

/** Which repository this is, read from the checkout rather than configured twice. */
function repoName() {
  if (process.env.SECURITY_REPO) return process.env.SECURITY_REPO
  try {
    const url = execFileSync("git", ["-C", root, "remote", "get-url", "origin"], { encoding: "utf8" })
    const match = url.trim().match(/[:/]([^/]+\/[^/]+?)(?:\.git)?$/)
    if (match) return match[1]
  } catch {
    /* not a checkout with a remote; fall through */
  }
  return null
}

const repo = repoName()
if (!repo) fail("could not tell which repository this is; set SECURITY_REPO")
const entry = config.openSource.repositories[repo]
if (!entry) fail(`security.config.json does not describe ${repo}`)

const { contact, disclosure, bounty, openSource } = config
const docsRepo = "https://github.com/safixlabs/safix-docs"

const reportingChannel = () => {
  if (contact.email) {
    const pgp = contact.pgpFingerprint
      ? `\n\nEncrypt anything sensitive to the PGP key \`${contact.pgpFingerprint}\`.`
      : ""
    return `Email **${contact.email}**. Include enough for us to reproduce it: the contract or the screen, the conditions it needs, and the impact you believe it has.${pgp}`
  }
  if (contact.githubAdvisories) {
    return "Open a private security advisory on this repository, under **Security → Report a vulnerability**. It stays private to you and the maintainers until it is published."
  }
  return [
    "**There is no published reporting channel yet.** This repository is private and no security",
    "address has been announced, so somebody outside the project currently has no way to report a",
    "vulnerability, and no responsible way to publish one either.",
    "",
    `Opening that channel is tracked in [${docsRepo}/issues/3](${docsRepo}/issues/3), and it has to be`,
    "open before anything reaches mainnet, and the protocol is already live on testnet. Until then:",
    "please do not disclose a finding",
    "in a public issue. Wait for the channel, or reach a maintainer privately through whoever gave you",
    "access to this repository."
  ].join("\n")
}

const timelines = () => {
  const days = disclosure.fixTargetDays
  return [
    `- **Acknowledgement** within ${disclosure.acknowledgeWithinHours} hours.`,
    `- **Triage and a severity** within ${disclosure.triageWithinDays} days, with the reasoning.`,
    `- **A fix** targeted at ${days.critical} days for critical, ${days.high} for high, ${days.medium} for medium, ${days.low} for low.`,
    `- **Publication** within ${disclosure.publicAfterFixDays} days of the fix shipping, crediting you unless you would rather we did not.`,
    `- **An embargo of no more than ${disclosure.maximumEmbargoDays} days.** If we cannot fix it in that time we will say so and agree a date with you rather than let it sit.`
  ].join("\n")
}

const rewards = () => {
  if (!bounty.live) {
    return [
      "**The bug bounty is not live.** The protocol is deployed to Robinhood Chain Testnet, where the",
      "tokens are test tokens and nothing at risk is worth anything, and no reward amounts have been",
      "signed off for mainnet. Publishing a table now would be a promise with no money behind it.",
      "",
      "The scope and the rules above are the programme; the reward table is the only part still missing,",
      "and it lands before the first mainnet transaction. Reports sent before then are still wanted,",
      "still triaged on the timelines above, and still credited."
    ].join("\n")
  }
  const currency = bounty.currency ? ` ${bounty.currency}` : ""
  return [
    "| Severity | Reward |",
    "| --- | --- |",
    `| Critical | ${bounty.rewards.critical}${currency} |`,
    `| High | ${bounty.rewards.high}${currency} |`,
    `| Medium | ${bounty.rewards.medium}${currency} |`,
    `| Low | ${bounty.rewards.low}${currency} |`,
    "",
    "Severity is ours to assign, with the reasoning given. Duplicates go to whoever reported first."
  ].join("\n")
}

const licenceLine = () =>
  entry.declaredLicense
    ? `The code here declares **${entry.declaredLicense}**${entry.licenseSource ? ` (${entry.licenseSource})` : ""}.`
    : "The licence for this repository has not been decided."

const openness = () => {
  if (entry.opensAt) return `It opens ${entry.opensAt}.`
  if (openSource.decided) return "Whether it opens has been decided; see the decision record."
  return `Whether it becomes public, and when, is not decided. That decision is due ${openSource.decisionDue} and is tracked in [${docsRepo}/issues/3](${docsRepo}/issues/3).`
}

const safeHarbour = disclosure.safeHarbour
  ? `We will not pursue or support legal action against anyone who reports in good faith under this
policy, stays inside the scope below, does not access, modify or destroy anyone else's data, and
gives us a reasonable chance to fix the problem before telling anyone else.

If a third party brings action against you for research that followed this policy, we will make it
known that it did.`
  : "No safe harbour has been agreed for this policy yet."

const document = `# Security policy

This policy covers **${repo}**: ${entry.contents.charAt(0).toLowerCase()}${entry.contents.slice(1)}.

Safix holds other people's collateral and other people's deposits, and the contracts have not been
through an independent security audit. If you find something, we want to hear about it before
anybody loses money.

## Reporting a vulnerability

${reportingChannel()}

Please do not open a public issue, post it publicly, or test against funds that are not yours.

## What happens next

${timelines()}

## Safe harbour

${safeHarbour}

## In scope

${bounty.inScope.map(item => `- ${item}`).join("\n")}

## Out of scope

${bounty.outOfScope.map(item => `- ${item}`).join("\n")}

## Rewards

${rewards()}

## About this repository

${licenceLine()} ${openness()}

---

Generated from \`security.config.json\` by \`scripts/build-security.mjs\`. Edit the configuration, not
this file.
`

writeFileSync(join(root, "SECURITY.md"), document)

// RFC 9116. Only a surface that serves files publishes one, and only when there
// is a contact to put in it: the format requires a Contact field, and a
// security.txt without one is not a weaker file, it is an invalid file.
const wellKnown = join(root, "public", ".well-known")
if (existsSync(join(root, "public"))) {
  const contactUri = contact.email
    ? `mailto:${contact.email}`
    : contact.githubAdvisories
      ? `https://github.com/${repo}/security/advisories/new`
      : null
  if (contactUri) {
    const expires = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toISOString().replace(/\.\d+Z$/, "Z")
    const lines = [
      `Contact: ${contactUri}`,
      `Expires: ${expires}`,
      "Preferred-Languages: en",
      `Policy: https://github.com/${repo}/blob/main/SECURITY.md`
    ]
    if (contact.pgpFingerprint) lines.splice(1, 0, `Encryption: ${contact.pgpFingerprint}`)
    mkdirSync(wellKnown, { recursive: true })
    writeFileSync(join(wellKnown, "security.txt"), `${lines.join("\n")}\n`)
    console.log("build-security: wrote public/.well-known/security.txt")
  } else {
    rmSync(join(wellKnown, "security.txt"), { force: true })
  }
}
console.log(
  `build-security: wrote SECURITY.md for ${repo} (channel: ${
    contact.email ?? (contact.githubAdvisories ? "github advisories" : "none published")
  }, bounty: ${bounty.live ? "live" : "not live"})`
)
