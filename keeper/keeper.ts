import {
  createPublicClient,
  createWalletClient,
  defineChain,
  getAddress,
  http,
  maxUint256,
  parseAbi,
  type PublicClient,
  type WalletClient
} from "viem"
import { privateKeyToAccount } from "viem/accounts"
import { createAlerter, liquidationsAffordable, type Alerter } from "./src/alerts.ts"
import { loadConfig, loadPrivateKey, type Config } from "./src/config.ts"
import { log, reason, setInstance } from "./src/log.ts"

const poolAbi = parseAbi([
  "function setPrice(address asset, uint256 priceUsd1e18)",
  "function currentPrice(address asset) view returns (uint256 price1e18, uint256 updatedAt)",
  "function isLiquidatable(address borrower, address asset) view returns (bool)",
  "function liquidate(address borrower, address asset, uint256 debtAmount)",
  "function positions(address borrower, address asset) view returns (uint256 collateral, uint256 debt, uint256 totalDrawn)",
  "function pausedActions() view returns (uint8)",
  "event Drawn(address indexed borrower, address indexed asset, uint256 amount, uint256 fee)"
])

const PAUSE_LIQUIDATIONS = 4

type Pair = { borrower: `0x${string}`; asset: `0x${string}` }

/// Reverts that mean another keeper got there first, or the position stopped being liquidatable
/// between the read and the send. Expected in normal operation with more than one keeper running,
/// so they are logged but never alerted on.
const BENIGN_REVERTS = ["healthy", "liquidations paused", "zero"]

const toPrice1e18 = (value: number) => BigInt(Math.round(value * 1e8)) * 10n ** 10n

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

/// Randomises the order positions are attempted in. Two keepers scanning the same pool at the
/// same moment would otherwise race on the same position every pass, wasting one of the two
/// transactions every time; shuffling means they mostly work on different ones.
function shuffled<T>(items: T[]): T[] {
  const copy = [...items]
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[copy[i], copy[j]] = [copy[j], copy[i]]
  }
  return copy
}

class Keeper {
  private readonly config: Config
  private readonly publicClient: PublicClient
  private readonly alerter: Alerter
  private readonly account: ReturnType<typeof privateKeyToAccount>
  private wallet: WalletClient | null = null

  /// How many consecutive scans each position has been liquidatable without being cleared.
  private readonly stuckFor = new Map<string, number>()

  constructor(config: Config, privateKey: `0x${string}`, alerter: Alerter) {
    this.config = config
    this.alerter = alerter
    this.account = privateKeyToAccount(privateKey)
    this.publicClient = createPublicClient({ transport: http(config.rpcUrl) })
  }

  get address() {
    return this.account.address
  }

  private async walletClient(): Promise<WalletClient> {
    if (this.wallet) return this.wallet
    const chainId = await this.publicClient.getChainId()
    const chain = defineChain({
      id: chainId,
      name: `chain-${chainId}`,
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [this.config.rpcUrl] } }
    })
    this.wallet = createWalletClient({ account: this.account, chain, transport: http(this.config.rpcUrl) })
    return this.wallet
  }

  /// Foundry's estimate runs short on this Orbit chain because of the L1 data component, and a
  /// liquidation that dies out of gas is a liquidation that did not happen.
  private async send(functionName: "liquidate" | "setPrice", args: readonly unknown[]) {
    const wallet = await this.walletClient()
    const estimate = await this.publicClient.estimateContractGas({
      account: this.account,
      address: this.config.poolAddress,
      abi: poolAbi,
      functionName,
      args: args as never
    })
    const hash = await wallet.writeContract({
      chain: wallet.chain,
      account: this.account,
      address: this.config.poolAddress,
      abi: poolAbi,
      functionName,
      args: args as never,
      gas: (estimate * 3n) / 2n
    })
    const receipt = await this.publicClient.waitForTransactionReceipt({ hash })
    return { hash, receipt }
  }

  // ----------------------------------------------------------------------------------------
  // gas
  // ----------------------------------------------------------------------------------------

  /// Reports the key's balance as the number of liquidations it can still afford, and alerts
  /// while there is still time to top it up rather than once it is already dry.
  private async checkGas() {
    const [balance, gasPrice] = await Promise.all([
      this.publicClient.getBalance({ address: this.account.address }),
      this.publicClient.getGasPrice()
    ])
    const remaining = liquidationsAffordable(balance, gasPrice, this.config.gas.liquidationGas)
    log.info("gas.balance", { wei: balance, gasPrice, liquidationsRemaining: remaining })

    if (remaining <= this.config.gas.criticalLiquidations) {
      await this.alerter.fire({
        kind: "gas_low",
        severity: "critical",
        key: this.account.address,
        message: `keeper key can afford only ${remaining} more liquidations`,
        fields: { address: this.account.address, balanceWei: balance.toString(), liquidationsRemaining: remaining }
      })
    } else if (remaining <= this.config.gas.warnLiquidations) {
      await this.alerter.fire({
        kind: "gas_low",
        severity: "warning",
        key: this.account.address,
        message: `keeper key is down to ${remaining} liquidations of gas`,
        fields: { address: this.account.address, balanceWei: balance.toString(), liquidationsRemaining: remaining }
      })
    }
    return remaining
  }

  // ----------------------------------------------------------------------------------------
  // prices
  // ----------------------------------------------------------------------------------------

  private async pushPrices() {
    const entries = Object.entries(this.config.prices) as [`0x${string}`, number][]
    if (entries.length === 0) return

    for (const [asset, price] of entries) {
      const target = toPrice1e18(price)
      try {
        const [current] = await this.publicClient.readContract({
          abi: poolAbi,
          address: this.config.poolAddress,
          functionName: "currentPrice",
          args: [asset]
        })
        if (current === target) continue
        const { hash } = await this.send("setPrice", [asset, target])
        log.info("price.set", { asset, price, hash })
      } catch (error) {
        // The pool refuses a price outside the asset's band or one that moves too far in a single
        // update. That is the oracle guard working, and it says nothing about the other assets.
        log.warn("price.rejected", { asset, price, reason: reason(error) })
      }
    }
  }

  // ----------------------------------------------------------------------------------------
  // positions
  // ----------------------------------------------------------------------------------------

  /// Discovers every borrower and asset pair that has ever drawn.
  ///
  /// The index is asked first when one is configured, and the log scan is what happens when it
  /// does not answer. That order matters both ways round: the scan replays the whole log history
  /// on every pass, which this chain's 689,000 blocks a day makes steadily more expensive — and
  /// liquidation is the one thing in the protocol that must not wait on a service the team runs.
  /// So the index makes the keeper cheaper and is never allowed to make it fragile.
  private async discoverPositions(): Promise<Pair[]> {
    if (this.config.indexerUrl) {
      const fromIndex = await this.positionsFromIndex(this.config.indexerUrl)
      if (fromIndex) return fromIndex
    }
    return this.positionsFromLogs()
  }

  /// Reads open positions from the index. Returns null on anything unexpected — unreachable,
  /// slow, malformed, stale — so the caller falls back rather than scanning a short list and
  /// believing it.
  private async positionsFromIndex(baseUrl: string): Promise<Pair[] | null> {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), this.config.indexerTimeoutMs)
    try {
      const status = await fetch(new URL("/status", baseUrl), { signal: controller.signal })
      if (!status.ok) throw new Error(`status ${status.status}`)
      const health = (await status.json()) as { cursor: number | null; blocksBehind: number | null }

      // An index that has fallen behind is worse than no index: it answers, so the fallback never
      // fires, and the positions it omits are exactly the newest ones. The keeper would rather
      // pay for a log scan than silently stop watching a position drawn five minutes ago.
      if (health.cursor === null) throw new Error("index has no cursor yet")
      if (health.blocksBehind !== null && health.blocksBehind > this.config.indexerMaxLagBlocks) {
        throw new Error(`index is ${health.blocksBehind} blocks behind`)
      }

      const response = await fetch(new URL("/positions?open=true", baseUrl), { signal: controller.signal })
      if (!response.ok) throw new Error(`positions ${response.status}`)
      const body = (await response.json()) as { positions?: { borrower?: string; asset?: string }[] }
      if (!Array.isArray(body.positions)) throw new Error("positions is not a list")

      const pairs: Pair[] = []
      for (const entry of body.positions) {
        // The index is a service the keeper does not control. Its rows are checked here rather
        // than trusted, because a malformed address would otherwise reach a contract call.
        if (!entry.borrower || !entry.asset) continue
        if (!/^0x[0-9a-fA-F]{40}$/.test(entry.borrower) || !/^0x[0-9a-fA-F]{40}$/.test(entry.asset)) continue
        pairs.push({ borrower: getAddress(entry.borrower), asset: getAddress(entry.asset) })
      }
      log.info("positions.from_index", { count: pairs.length, blocksBehind: health.blocksBehind })
      return pairs
    } catch (error) {
      log.warn("positions.index_unavailable", { reason: reason(error), falling_back: "log scan" })
      return null
    } finally {
      clearTimeout(timer)
    }
  }

  /// The original discovery: replay every Drawn event from the deploy block, in chunks the RPC
  /// will accept. Correct, self-sufficient, and slower every day the chain runs.
  private async positionsFromLogs(): Promise<Pair[]> {
    const latest = await this.publicClient.getBlockNumber()
    const pairs = new Map<string, Pair>()
    const event = poolAbi.find(item => item.type === "event" && item.name === "Drawn")

    for (let from = this.config.deployBlock; from <= latest; from += this.config.logChunkBlocks) {
      const to = from + this.config.logChunkBlocks - 1n
      const logs = await this.publicClient.getLogs({
        address: this.config.poolAddress,
        event: event as never,
        fromBlock: from,
        toBlock: to > latest ? latest : to
      })
      for (const entry of logs) {
        const borrower = (entry as { args?: Pair }).args?.borrower
        const asset = (entry as { args?: Pair }).args?.asset
        if (!borrower || !asset) continue
        pairs.set(`${borrower}:${asset}`, { borrower, asset })
      }
    }
    return [...pairs.values()]
  }

  /// Liquidating is idempotent by construction: the pool answers isLiquidatable false the moment
  /// somebody else clears a position, and refuses the call outright if it is already healthy. Two
  /// keepers racing therefore cost one wasted transaction, never a double liquidation.
  private async liquidateUnhealthy() {
    const paused = await this.publicClient.readContract({
      abi: poolAbi,
      address: this.config.poolAddress,
      functionName: "pausedActions"
    })
    if ((Number(paused) & PAUSE_LIQUIDATIONS) !== 0) {
      log.warn("scan.liquidations_paused", { pausedActions: Number(paused) })
      return
    }

    const pairs = await this.discoverPositions()
    log.info("scan.positions", { count: pairs.length })

    const seen = new Set<string>()
    for (const { borrower, asset } of shuffled(pairs)) {
      const key = `${borrower}:${asset}`
      seen.add(key)
      try {
        const liquidatable = await this.publicClient.readContract({
          abi: poolAbi,
          address: this.config.poolAddress,
          functionName: "isLiquidatable",
          args: [borrower, asset]
        })
        if (!liquidatable) {
          this.stuckFor.delete(key)
          continue
        }

        const [, debt] = await this.publicClient.readContract({
          abi: poolAbi,
          address: this.config.poolAddress,
          functionName: "positions",
          args: [borrower, asset]
        })

        const { hash, receipt } = await this.send("liquidate", [borrower, asset, maxUint256])
        if (receipt.status === "success") {
          log.info("liquidated", { borrower, asset, debt, hash, gasUsed: receipt.gasUsed })
          this.stuckFor.delete(key)
        } else {
          this.stuckFor.set(key, (this.stuckFor.get(key) ?? 0) + 1)
          await this.alerter.fire({
            kind: "tx_reverted",
            severity: "warning",
            key,
            message: `liquidation transaction reverted onchain for ${borrower} on ${asset}`,
            fields: { borrower, asset, hash }
          })
        }
      } catch (error) {
        const why = reason(error)
        const benign = BENIGN_REVERTS.some(text => why.includes(text))
        const count = (this.stuckFor.get(key) ?? 0) + 1
        this.stuckFor.set(key, count)

        if (benign) {
          log.info("liquidation.skipped", { borrower, asset, reason: why })
          this.stuckFor.delete(key)
          continue
        }

        log.warn("liquidation.failed", { borrower, asset, reason: why, consecutive: count })
        if (count === 1) {
          await this.alerter.fire({
            kind: "tx_reverted",
            severity: "warning",
            key,
            message: `liquidation failed for ${borrower} on ${asset}: ${why}`,
            fields: { borrower, asset, reason: why }
          })
        }
        if (count >= this.config.alerts.stuckScans) {
          await this.alerter.fire({
            kind: "position_stuck",
            severity: "critical",
            key,
            message: `position has been liquidatable for ${count} consecutive scans and is still open`,
            fields: { borrower, asset, consecutiveScans: count, reason: why }
          })
        }
      }
    }

    // Positions that no longer exist stop being tracked, so a restarted keeper does not carry a
    // stale stuck count forever.
    for (const key of [...this.stuckFor.keys()]) {
      if (!seen.has(key)) this.stuckFor.delete(key)
    }
  }

  // ----------------------------------------------------------------------------------------
  // the loop
  // ----------------------------------------------------------------------------------------

  async scanOnce() {
    await this.checkGas()
    // Liquidation is the pool's only defence and must not depend on the price push succeeding.
    try {
      await this.pushPrices()
    } catch (error) {
      log.warn("price.phase_failed", { reason: reason(error) })
    }
    await this.liquidateUnhealthy()
  }

  async watch() {
    log.info("keeper.start", {
      pool: this.config.poolAddress,
      rpc: this.config.rpcUrl,
      account: this.account.address,
      intervalMs: this.config.intervalMs
    })
    let consecutiveFailures = 0
    for (;;) {
      const startedAt = Date.now()
      try {
        await this.scanOnce()
        if (consecutiveFailures > 0) log.info("scan.recovered", { afterFailures: consecutiveFailures })
        consecutiveFailures = 0
        log.info("scan.complete", { durationMs: Date.now() - startedAt })
      } catch (error) {
        consecutiveFailures += 1
        const why = reason(error)
        log.error("scan.failed", { reason: why, consecutive: consecutiveFailures })
        await this.alerter.fire({
          kind: "scan_failed",
          severity: consecutiveFailures >= 3 ? "critical" : "warning",
          key: "scan",
          message: `scan failed ${consecutiveFailures} time(s) in a row: ${why}`,
          fields: { reason: why, consecutive: consecutiveFailures }
        })
      }
      // Back off when the chain or the RPC is unhappy, so a broken endpoint is not hammered.
      const backoff = Math.min(consecutiveFailures, 5)
      await sleep(this.config.intervalMs * (backoff > 0 ? 2 ** backoff : 1))
    }
  }

  /// Sends one of each alert so the channel, the routing and the on-call rotation can be tested
  /// without waiting for a real incident.
  async drill() {
    log.info("drill.start", { account: this.account.address })
    const alerts = [
      { kind: "scan_failed", severity: "warning", key: "drill", message: "DRILL: scan failure" },
      { kind: "tx_reverted", severity: "warning", key: "drill", message: "DRILL: liquidation reverted" },
      { kind: "position_stuck", severity: "critical", key: "drill", message: "DRILL: position stuck across scans" },
      { kind: "gas_low", severity: "critical", key: "drill", message: "DRILL: keeper key running out of gas" }
    ] as const
    for (const alert of alerts) {
      await this.alerter.fire({ ...alert, fields: { drill: true } })
    }
    log.info("drill.complete", { fired: this.alerter.sent.length })
    return this.alerter.sent.length
  }
}

// --- entry point ---------------------------------------------------------------------------

const mode = process.argv[2] ?? "scan"
const config = loadConfig(process.env.CONFIG ?? "./config.json")
setInstance(config.instanceId)

const alerter = createAlerter(config.alerts.webhookUrl, config.alerts.cooldownMs, config.instanceId)
const keeper = new Keeper(config, loadPrivateKey(), alerter)

if (!config.alerts.webhookUrl) {
  log.warn("alerts.no_webhook", { hint: "set ALERT_WEBHOOK_URL; alerts will only reach the log" })
}

// A crash must restart, not exit quietly and leave the pool unwatched. The host restarts on a
// non-zero exit; these handlers make sure one happens rather than the process lingering wedged.
process.on("unhandledRejection", error => {
  log.error("keeper.unhandled_rejection", { reason: reason(error) })
  process.exit(1)
})
process.on("uncaughtException", error => {
  log.error("keeper.uncaught_exception", { reason: reason(error) })
  process.exit(1)
})
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    log.info("keeper.stopping", { signal })
    process.exit(0)
  })
}

if (mode === "watch") {
  await keeper.watch()
} else if (mode === "drill") {
  const fired = await keeper.drill()
  if (fired === 0) {
    log.error("drill.nothing_fired", {})
    process.exit(1)
  }
} else {
  await keeper.scanOnce()
  log.info("scan.complete", {})
}
