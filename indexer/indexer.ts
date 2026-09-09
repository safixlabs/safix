import { createPublicClient, http, type Address } from "viem"
import { createApi, type Health } from "./src/api.ts"
import { loadConfig, type Config } from "./src/config.ts"
import { Store } from "./src/db.ts"
import { rebuild } from "./src/fold.ts"
import { log, reason, setInstance } from "./src/log.ts"
import { Syncer } from "./src/sync.ts"

/// The Safix event indexer.
///
///   sync       one pass, then exit
///   watch      the loop, with the read API alongside it
///   serve      the read API alone, against whatever the file already holds
///   status     what the index knows, printed
///   reconcile  fold against chain, and say whether they agree
///
/// Why this exists rather than a subgraph or Ponder: README.md, with the measurements.

const POOL_ABI = [
  { type: "function", name: "totalDeposits", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalDebt", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "positions",
    stateMutability: "view",
    inputs: [
      { name: "borrower", type: "address" },
      { name: "asset", type: "address" }
    ],
    outputs: [
      { name: "collateral", type: "uint256" },
      { name: "debt", type: "uint256" },
      { name: "totalDrawn", type: "uint256" }
    ]
  }
] as const

const configPath = process.env.CONFIG ?? "./config.json"

function build(): { config: Config; store: Store; client: ReturnType<typeof createPublicClient> } {
  const config = loadConfig(configPath)
  setInstance(config.instanceId)
  const store = new Store(config.databasePath)
  const client = createPublicClient({
    transport: http(config.rpcUrl, {
      // The node accepts a JSON-RPC batch of exactly 100 and answers 429 above it. Batching is
      // what makes fetching block timestamps affordable; see README.md for the measurement.
      batch: { batchSize: 100, wait: 20 },
      retryCount: 3,
      timeout: 30_000
    })
  })
  return { config, store, client }
}

async function runSync(config: Config, store: Store, client: ReturnType<typeof createPublicClient>) {
  const syncer = new Syncer(config, client, store)
  const started = Date.now()
  const result = await syncer.syncOnce()
  log.info("sync.pass", {
    from: result.fromBlock,
    to: result.toBlock,
    events: result.events,
    prices: result.prices,
    chunks: result.chunks,
    rewound: result.rewound,
    ms: Date.now() - started
  })
  return result
}

async function commandSync() {
  const { config, store, client } = build()
  try {
    await runSync(config, store, client)
    printStatus(config, store)
  } finally {
    store.close()
  }
}

async function commandWatch() {
  const { config, store, client } = build()
  const syncer = new Syncer(config, client, store)
  const health: Health = { head: null, lastPassAt: null, lastError: null }

  const server = createApi(config, store, () => health)
  server.listen(config.port, () => log.info("api.listening", { port: config.port }))

  let stopping = false
  const stop = (signal: string) => {
    if (stopping) return
    stopping = true
    log.info("shutdown", { signal })
    server.close()
    store.close()
    process.exit(0)
  }
  process.on("SIGINT", () => stop("SIGINT"))
  process.on("SIGTERM", () => stop("SIGTERM"))

  // The loop deliberately does not exit on a failed pass. The RPC being briefly unavailable is
  // ordinary, and an index that quits on it stops serving history that is already stored and
  // still correct. What it must not do is fail silently: the error is logged and surfaced on
  // /status, so a monitor can see an index that has stopped advancing.
  for (;;) {
    if (stopping) return
    try {
      const result = await runSync(config, store, client)
      health.head = result.toBlock
      health.lastPassAt = Math.floor(Date.now() / 1000)
      health.lastError = null
    } catch (error) {
      health.lastError = reason(error)
      log.error("sync.failed", { reason: health.lastError })
    }
    await new Promise(resolve => setTimeout(resolve, config.intervalMs))
  }
}

function commandServe() {
  const { config, store } = build()
  const health: Health = { head: null, lastPassAt: null, lastError: "not syncing: serve mode" }
  const server = createApi(config, store, () => health)
  server.listen(config.port, () =>
    log.info("api.listening", { port: config.port, mode: "serve", note: "read-only, no sync loop" })
  )
  process.on("SIGTERM", () => {
    server.close()
    store.close()
    process.exit(0)
  })
}

function printStatus(config: Config, store: Store) {
  const counts = store.counts()
  const cursor = store.lastBlock()
  const point = store.latestPoolPoint()
  log.info("status", {
    pool: config.poolAddress,
    desk: config.deskAddress,
    registry: config.registryAddress,
    cursor: cursor === null ? "none" : cursor,
    ...counts,
    totalDeposits: point?.deposits ?? 0n,
    totalDebt: point?.debt ?? 0n
  })
}

async function commandStatus() {
  const { config, store } = build()
  printStatus(config, store)
  store.close()
}

/// Proves the fold against the chain.
///
/// The index derives the pool's size, its debt and every position from events alone, because the
/// node cannot answer for a block more than about thirteen minutes old. That derivation is only
/// worth trusting if it lands on the same numbers the contract holds right now, so this syncs to
/// the head and compares, position by position. Exits non-zero on any disagreement, which makes
/// it usable as a check rather than only as a report.
async function commandReconcile() {
  const { config, store, client } = build()
  let mismatches = 0
  try {
    const result = await runSync(config, store, client)
    const at = result.toBlock

    // Rebuilding from the stored events, rather than trusting the incremental fold, checks two
    // things at once: that the fold is right, and that folding all of it agrees with folding it
    // in pieces as the events arrived.
    const folded = rebuild(store)

    const [chainDeposits, chainDebt] = (await Promise.all([
      client.readContract({ abi: POOL_ABI, address: config.poolAddress, functionName: "totalDeposits", blockNumber: at }),
      client.readContract({ abi: POOL_ABI, address: config.poolAddress, functionName: "totalDebt", blockNumber: at })
    ])) as [bigint, bigint]

    const report = (label: string, indexed: bigint, chain: bigint) => {
      const agree = indexed === chain
      if (!agree) mismatches += 1
      log[agree ? "info" : "error"](agree ? "reconcile.match" : "reconcile.mismatch", {
        field: label,
        indexed,
        chain,
        difference: indexed - chain
      })
    }

    report("totalDeposits", folded.pool.deposits, chainDeposits)
    report("totalDebt", folded.pool.debt, chainDebt)

    for (const [id, position] of folded.positions) {
      const [borrower, asset] = id.split(":")
      const onChain = (await client.readContract({
        abi: POOL_ABI,
        address: config.poolAddress,
        functionName: "positions",
        args: [borrower as Address, asset as Address],
        blockNumber: at
      })) as readonly [bigint, bigint, bigint]
      report(`${borrower}/${asset} collateral`, position.collateral, onChain[0])
      report(`${borrower}/${asset} debt`, position.debt, onChain[1])
      report(`${borrower}/${asset} totalDrawn`, position.totalDrawn, onChain[2])
    }

    log.info("reconcile.done", { block: at, positions: folded.positions.size, mismatches })
  } finally {
    store.close()
  }
  if (mismatches > 0) process.exit(1)
}

const command = process.argv[2] ?? "watch"
const run =
  command === "sync"
    ? commandSync
    : command === "serve"
      ? async () => commandServe()
      : command === "status"
        ? commandStatus
        : command === "reconcile"
          ? commandReconcile
          : command === "watch"
            ? commandWatch
            : null

if (!run) {
  console.error(`unknown command: ${command}\nusage: indexer.ts [sync|watch|serve|status|reconcile]`)
  process.exit(2)
}

run().catch(error => {
  // Exiting non-zero is what makes a host's restart policy fire. A worker that dies quietly is
  // indistinguishable from one that is merely idle.
  log.error("fatal", { reason: reason(error) })
  process.exit(1)
})
