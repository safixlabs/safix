// Asks Chainlink whether it publishes an L2 sequencer uptime feed for Robinhood Chain (#38).
//
//   node scripts/check-sequencer-feed.mjs                       print the answer
//   node scripts/check-sequencer-feed.mjs --report 38           and keep one comment on #38 current
//   node scripts/check-sequencer-feed.mjs --report 38 --dry-run print that comment instead of posting it
//   node scripts/check-sequencer-feed.mjs --watchdog            fail if the weekly check has stopped
//
// The watchdog exists because a check that stops running does not fail. GitHub disables scheduled
// workflows in a public repository after 60 days without activity, and a disabled workflow runs on
// no trigger at all, so the guard cannot live inside it. The contracts workflow runs it on every push
// and pull request: it fails while sequencer-feed.yml is disabled, or when its last run is older than
// a week and a day.
//
// Exit codes: 0 when no feed is published and the check provably worked, 2 when a feed is published
// and has to be wired, 1 when the check could not be made. A check that could not read its sources
// never reports "none": an unanswered question is not an answer.
//
// Two sources, because either can change without the other. Chainlink's reference data directory is
// the machine-readable list behind its documentation; the documentation page carries the list a
// reader sees and the notice that no new networks are being added. Each source is checked against a
// network that is known to have a feed, so a change in either format fails the check rather than
// quietly finding nothing.

import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const CHAIN_ID = 4663
const DIRECTORY = "https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json"
const CONTROL_DIRECTORY = "https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json"
const CONTROL_FEED = "0xFdB631F5EE196F0ed6FAa767959853A9F217697D" // Arbitrum One's, as Chainlink lists it
const DOCS = "https://docs.chain.link/data-feeds/l2-sequencer-feeds"
const MARKER = "<!-- sequencer-feed-check -->"
const TIMEOUT_MS = 20_000

const WORKFLOW = "sequencer-feed.yml"
// When the schedule fires, and how late a run may be before the watchdog calls it stopped: a week,
// plus a day for GitHub's own scheduling delay.
const SCHEDULE = { weekday: 1, hour: 6, minute: 17 }
const MAX_RUN_AGE_MS = 8 * 24 * 60 * 60 * 1000

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const workflowCron = readFileSync(join(root, ".github", "workflows", WORKFLOW), "utf8").match(/cron:\s*"([^"]+)"/)?.[1]
if (workflowCron !== `${SCHEDULE.minute} ${SCHEDULE.hour} * * ${SCHEDULE.weekday}`) {
  console.error(`check-sequencer-feed: ${WORKFLOW} runs on "${workflowCron}", which this script does not describe`)
  process.exit(1)
}

/** The first scheduled run strictly after `from`. */
function nextScheduledRun(from) {
  const next = new Date(from)
  next.setUTCHours(SCHEDULE.hour, SCHEDULE.minute, 0, 0)
  const days = (SCHEDULE.weekday - next.getUTCDay() + 7) % 7
  next.setUTCDate(next.getUTCDate() + days)
  if (next <= from) next.setUTCDate(next.getUTCDate() + 7)
  return next
}

const args = process.argv.slice(2)
const watchdog = args.includes("--watchdog")
const reportIssue = args.includes("--report") ? Number(args[args.indexOf("--report") + 1]) : null
const dryRun = args.includes("--dry-run")

const inconclusive = message => {
  console.error(`check-sequencer-feed: could not make the check: ${message}`)
  process.exit(1)
}

async function fetchText(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) })
  if (!response.ok) throw new Error(`${url} answered HTTP ${response.status}`)
  return response.text()
}

/** Directory entries Chainlink marks as sequencer uptime feeds. */
const uptimeFeeds = feeds =>
  feeds.filter(
    feed => feed?.docs?.attributeType === "l2_sequencer_uptime_status" || /sequencer uptime/i.test(feed?.name ?? "")
  )

async function checkDirectory() {
  let control
  try {
    control = JSON.parse(await fetchText(CONTROL_DIRECTORY))
  } catch (error) {
    inconclusive(`the control directory: ${error.message}`)
  }
  const controlHit = uptimeFeeds(control).find(feed => feed.proxyAddress?.toLowerCase() === CONTROL_FEED.toLowerCase())
  if (!controlHit) inconclusive("the directory no longer marks Arbitrum One's uptime feed the way this check reads it")

  let feeds
  try {
    feeds = JSON.parse(await fetchText(DIRECTORY))
  } catch (error) {
    inconclusive(`the Robinhood Chain directory: ${error.message}`)
  }
  if (!Array.isArray(feeds) || feeds.length === 0) inconclusive("the Robinhood Chain directory lists no feeds at all")
  return { listed: feeds.length, uptime: uptimeFeeds(feeds).map(feed => ({ name: feed.name, address: feed.proxyAddress })) }
}

/**
 * The networks named in the documentation's list. Each entry reads as a heading, then its label,
 * then the address — "Metis Metis Andromeda Mainnet: 0x…" — so the label is what follows the
 * heading's repetition. Split on the addresses rather than guessing at capitalisation, which is how
 * "zkSync" and "X Layer" both stay whole.
 */
function networksIn(list) {
  const chunks = list.split(/0x[0-9a-fA-F]{40}/).slice(0, -1)
  return chunks.map((chunk, index) => {
    const beforeColon = (index === 0 ? chunk.slice(chunk.indexOf(":") + 1) : chunk).replace(/\s*Mainnet:\s*$/, "").trim()
    const words = beforeColon.split(" ")
    for (let size = 1; size <= words.length / 2; size += 1) {
      const heading = words.slice(0, size).join(" ")
      const label = words.slice(size).join(" ")
      if (label.toLowerCase().startsWith(heading.toLowerCase())) return label
    }
    return beforeColon
  })
}

async function checkDocs() {
  let raw
  try {
    raw = await fetchText(DOCS)
  } catch (error) {
    inconclusive(`the documentation page: ${error.message}`)
  }
  const text = raw
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&[a-z]+;|&#\d+;/gi, " ")
    .replace(/\s+/g, " ")
  // The list of networks sits between this sentence and the example code that follows it.
  const start = text.search(/L2 sequencer feeds at the following addresses/i)
  if (start < 0) inconclusive("the documentation page no longer carries its list of sequencer feed addresses")
  const rest = text.slice(start)
  const endCandidates = ["GRACE_PERIOD_TIME", "Example code", "Handling outages"].map(word => rest.indexOf(word)).filter(i => i > 0)
  const list = rest.slice(0, endCandidates.length > 0 ? Math.min(...endCandidates) : 4000)
  if (!list.includes(CONTROL_FEED)) inconclusive("the documentation's list no longer shows Arbitrum One's feed where this check reads it")
  const networks = networksIn(list)
  return {
    networks,
    namesRobinhood: /robinhood/i.test(list),
    notice: /no longer expanding L2 Sequencer Uptime Feeds/i.test(text)
  }
}

function repository() {
  if (process.env.GITHUB_REPOSITORY) return process.env.GITHUB_REPOSITORY
  const url = execFileSync("git", ["remote", "get-url", "origin"], { encoding: "utf8" }).trim()
  const match = url.match(/[:/]([^/]+\/[^/]+?)(?:\.git)?$/)
  if (!match) throw new Error(`cannot read the repository from ${url}`)
  return match[1]
}

function commentBody(result) {
  const { directory, docs, found, checkedAt } = result
  const run =
    process.env.GITHUB_RUN_ID && process.env.GITHUB_SERVER_URL
      ? `[this run](${process.env.GITHUB_SERVER_URL}/${repository()}/actions/runs/${process.env.GITHUB_RUN_ID})`
      : "a local run"
  const lines = [
    MARKER,
    "### Sequencer uptime feed for Robinhood Chain",
    "",
    found
      ? `**Published.** Chainlink now lists an L2 sequencer uptime feed for chain ${CHAIN_ID}. It has to be wired.`
      : `**Not published.** Chainlink lists no L2 sequencer uptime feed for chain ${CHAIN_ID}.`,
    "",
    `Checked ${checkedAt} by ${run}. This comment is rewritten on every weekly check, so it always carries the latest answer.`,
    "",
    `Next scheduled check: **${nextScheduledRun(new Date(checkedAt)).toISOString().replace(/:00\.000Z$/, " UTC")}**. If that is in the past, the weekly check has stopped rather than failed: GitHub disables scheduled workflows in a public repository after 60 days without activity. Re-enable it with \`gh workflow enable ${WORKFLOW}\`; until then the \`contracts\` workflow fails on every push.`,
    "",
    "| Source | What it says |",
    "| --- | --- |",
    `| [Reference data directory](${DIRECTORY}), the data behind Chainlink's documentation | ${directory.listed} feeds listed for chain ${CHAIN_ID}; ${
      directory.uptime.length === 0
        ? "none of them a sequencer uptime feed"
        : directory.uptime.map(feed => `\`${feed.address}\` (${feed.name})`).join(", ")
    } |`,
    `| [L2 sequencer feeds page](${DOCS}) | ${docs.networks.length} networks listed (${docs.networks.join(", ")}); Robinhood Chain ${
      docs.namesRobinhood ? "**is** among them" : "is not among them"
    } |`,
    `| The same page's availability notice | ${
      docs.notice
        ? "still says Chainlink is no longer expanding uptime feeds to additional networks"
        : "**no longer present** — Chainlink may be adding networks again"
    } |`,
    "",
    "Both sources are checked against Arbitrum One's published feed first, so a change in either format fails the run instead of reporting nothing found.",
    "",
    found
      ? [
          "**What to do now:**",
          "",
          "1. Confirm the address against Chainlink's documentation, not only this comment.",
          "2. Wire it: `SEQUENCER_UPTIME_FEED` and `SEQUENCER_GRACE_PERIOD` on the next deploy, or `setSequencerUptimeFeed(feed, gracePeriod)` from the owner, which needs no timelock. Chainlink's own example uses a one-hour grace period.",
          "3. Re-check the exit table in `contracts/README.md` against the wired feed, as #38 asks."
        ].join("\n")
      : "Until one is published the pool runs without a sequencer check, as `contracts/README.md` describes. `Deploy.s.sol` wires one the day it exists."
  ]
  return lines.join("\n")
}

async function report(issue, body) {
  const token = process.env.GITHUB_TOKEN
  if (!token) inconclusive("--report needs GITHUB_TOKEN")
  const repo = repository()
  const api = `https://api.github.com/repos/${repo}/issues`
  const headers = { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "content-type": "application/json" }
  let existing = null
  for (let page = 1; !existing; page += 1) {
    const response = await fetch(`${api}/${issue}/comments?per_page=100&page=${page}`, { headers, signal: AbortSignal.timeout(TIMEOUT_MS) })
    if (!response.ok) inconclusive(`listing comments on #${issue}: HTTP ${response.status}`)
    const comments = await response.json()
    existing = comments.find(comment => comment.body?.includes(MARKER)) ?? null
    if (comments.length < 100) break
  }
  const url = existing ? `${api}/comments/${existing.id}` : `${api}/${issue}/comments`
  const response = await fetch(url, { method: existing ? "PATCH" : "POST", headers, body: JSON.stringify({ body }), signal: AbortSignal.timeout(TIMEOUT_MS) })
  if (!response.ok) inconclusive(`writing the comment on #${issue}: HTTP ${response.status}`)
  const written = await response.json()
  console.log(`check-sequencer-feed: ${existing ? "updated" : "posted"} ${written.html_url}`)
}

async function checkAlive() {
  const token = process.env.GITHUB_TOKEN
  if (!token) inconclusive("--watchdog needs GITHUB_TOKEN")
  const repo = repository()
  const headers = { authorization: `Bearer ${token}`, accept: "application/vnd.github+json" }
  const get = async path => {
    const response = await fetch(`https://api.github.com/repos/${repo}/actions/workflows/${WORKFLOW}${path}`, {
      headers,
      signal: AbortSignal.timeout(TIMEOUT_MS)
    })
    if (!response.ok) inconclusive(`reading ${WORKFLOW}${path}: HTTP ${response.status}`)
    return response.json()
  }
  const workflow = await get("")
  const { workflow_runs: runs } = await get("/runs?status=completed&per_page=1")
  const now = Date.now()
  const last = runs[0] ?? null
  const problems = []
  if (workflow.state !== "active") {
    problems.push(`${WORKFLOW} is ${workflow.state}; re-enable it with: gh workflow enable ${WORKFLOW}`)
  }
  if (last === null) {
    if (now - Date.parse(workflow.created_at) > MAX_RUN_AGE_MS) problems.push(`${WORKFLOW} has never completed a run`)
  } else if (now - Date.parse(last.created_at) > MAX_RUN_AGE_MS) {
    problems.push(`${WORKFLOW} last ran ${last.created_at}, more than eight days ago`)
  }
  const lastText = last ? `last run ${last.created_at} (${last.event}, ${last.conclusion})` : "no completed run yet"
  if (problems.length > 0) {
    console.error(`check-sequencer-feed: the weekly check has stopped · state ${workflow.state} · ${lastText}`)
    for (const problem of problems) console.error(`  - ${problem}`)
    process.exit(1)
  }
  console.log(`check-sequencer-feed: the weekly check is running · state ${workflow.state} · ${lastText}`)
  process.exit(0)
}

if (watchdog) await checkAlive()

const directory = await checkDirectory()
const docs = await checkDocs()
const found = directory.uptime.length > 0 || docs.namesRobinhood
const result = { directory, docs, found, checkedAt: new Date().toISOString().replace(/\.\d+Z$/, "Z") }

console.log(
  `check-sequencer-feed: ${found ? "PUBLISHED" : "not published"} for chain ${CHAIN_ID} · directory: ${directory.listed} feeds, ${directory.uptime.length} uptime · docs: ${docs.networks.length} networks, Robinhood ${docs.namesRobinhood ? "listed" : "not listed"}, notice ${docs.notice ? "in place" : "gone"}`
)

if (reportIssue) {
  const body = commentBody(result)
  if (dryRun) console.log(`\n--- the comment #${reportIssue} would carry ---\n${body}`)
  else await report(reportIssue, body)
}

process.exit(found ? 2 : 0)
