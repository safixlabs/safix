import { createPublicClient, http, type PublicClient } from "viem"
import { createAlerter, liquidationsAffordable, pct, usd, type Alerter } from "./src/alerts.ts"
import { loadConfig, type Config } from "./src/config.ts"
import { log, reason, setInstance } from "./src/log.ts"
import { discoverPositions, readSnapshot, recentFlows, type Snapshot } from "./src/metrics.ts"

/// Watches the protocol and says when something is wrong. It holds no key: it can read the chain
/// and send a message, and nothing else. The thing watching the protocol should not be able to
/// move it, so even a fully compromised monitor costs an incident report and no funds.

const PAUSE_NAMES = ["draws", "deposits", "liquidations"]

const pausedList = (mask: number) =>
  PAUSE_NAMES.filter((_, index) => (mask & (1 << index)) !== 0).join(", ") || "none"

class Monitor {
  private readonly config: Config
  private readonly client: PublicClient
  private readonly alerter: Alerter

  /// When each position was first seen liquidatable, so "for more than N minutes" is answerable.
  /// Held in memory rather than a database: losing it on restart delays an alert by one window,
  /// which is a smaller cost than a database to keep running.
  private readonly liquidatableSince = new Map<string, number>()

  /// Flows already reported, so the same deposit is not alerted on every pass while it stays
  /// inside the lookback window.
  private readonly reportedFlows = new Set<string>()

  constructor(config: Config, alerter: Alerter) {
    this.config = config
    this.alerter = alerter
    this.client = createPublicClient({ transport: http(config.rpcUrl) })
  }

  // ----------------------------------------------------------------------------------------
  // the checks
  // ----------------------------------------------------------------------------------------

  private async checkUtilisation(snapshot: Snapshot) {
    const { utilisationBps } = this.config.thresholds
    if (snapshot.utilisationBps < utilisationBps) return
    await this.alerter.fire({
      kind: "utilisation_high",
      severity: snapshot.utilisationBps >= 9_500 ? "critical" : "warning",
      key: "pool",
      message: `utilisation is ${pct(snapshot.utilisationBps)}, above the ${pct(utilisationBps)} threshold`,
      fields: {
        utilisation: pct(snapshot.utilisationBps),
        poolSize: usd(snapshot.poolSize),
        totalDebt: usd(snapshot.totalDebt),
        availableLiquidity: usd(snapshot.availableLiquidity)
      }
    })
  }

  /// Two alerts from one observation, separated by how long it has lasted. A position that is
  /// briefly liquidatable is normal and is what the keeper exists for. One that stays liquidatable
  /// is not a position problem: it means nothing is clearing it.
  private async checkPositions(snapshot: Snapshot) {
    const now = snapshot.timestamp
    const { positionAtRiskSeconds, keeperSilentSeconds } = this.config.thresholds
    const live = new Set<string>()

    for (const position of snapshot.positions) {
      const key = `${position.borrower}:${position.asset}`
      if (!position.liquidatable) {
        this.liquidatableSince.delete(key)
        continue
      }
      live.add(key)
      const since = this.liquidatableSince.get(key) ?? now
      this.liquidatableSince.set(key, since)
      const elapsed = now - since

      if (elapsed >= keeperSilentSeconds) {
        await this.alerter.fire({
          kind: "keeper_silent",
          severity: "critical",
          key,
          message: `a position has been liquidatable for ${Math.round(elapsed / 60)} minutes and nothing has cleared it`,
          fields: {
            borrower: position.borrower,
            asset: position.asset,
            debt: usd(position.debt),
            minutes: Math.round(elapsed / 60)
          }
        })
      } else if (elapsed >= positionAtRiskSeconds) {
        await this.alerter.fire({
          kind: "position_at_risk",
          severity: "warning",
          key,
          message: `a position has been liquidatable for ${Math.round(elapsed / 60)} minutes`,
          fields: { borrower: position.borrower, asset: position.asset, debt: usd(position.debt) }
        })
      }
    }

    for (const key of [...this.liquidatableSince.keys()]) {
      if (!live.has(key)) this.liquidatableSince.delete(key)
    }
  }

  /// Fires before the pool refuses the price, not after. Once the pool refuses it, draws and
  /// liquidations are already blocked; the useful moment is while there is still time to look.
  private async checkOracles(snapshot: Snapshot) {
    for (const asset of snapshot.assets) {
      if (!asset.enabled) continue

      if (asset.priceStatus !== "Ok") {
        await this.alerter.fire({
          kind: "stale_price",
          severity: "critical",
          key: asset.address,
          message: `the pool will not act on ${asset.address}: ${asset.priceStatus}`,
          fields: { asset: asset.address, status: asset.priceStatus, ageSeconds: asset.oracleAgeSeconds }
        })
        continue
      }

      if (asset.maxPriceAge === null) continue
      const warnAt = asset.maxPriceAge * this.config.thresholds.oracleAgeWarningRatio
      if (asset.oracleAgeSeconds >= warnAt) {
        await this.alerter.fire({
          kind: "stale_price",
          severity: "warning",
          key: asset.address,
          message: `price for ${asset.address} is ${asset.oracleAgeSeconds}s old, against a ${asset.maxPriceAge}s limit`,
          fields: { asset: asset.address, ageSeconds: asset.oracleAgeSeconds, maxPriceAge: asset.maxPriceAge }
        })
      }
    }
  }

  private async checkFlows(snapshot: Snapshot) {
    if (snapshot.poolSize === 0n) return
    const flows = await recentFlows(this.client, this.config.poolAddress, this.config.thresholds.flowWindowBlocks)
    const threshold = (snapshot.poolSize * BigInt(this.config.thresholds.largeFlowBps)) / 10_000n

    for (const flow of flows) {
      if (flow.amount < threshold) continue
      const key = `${flow.kind}:${flow.who}:${flow.block}:${flow.amount}`
      if (this.reportedFlows.has(key)) continue
      this.reportedFlows.add(key)
      await this.alerter.fire({
        kind: "large_flow",
        severity: "warning",
        key,
        message: `a single ${flow.kind} of ${usd(flow.amount)} against a pool of ${usd(snapshot.poolSize)}`,
        fields: { kind: flow.kind, who: flow.who, amount: usd(flow.amount), block: flow.block.toString() }
      })
    }
    // Forget flows that have fallen out of the lookback window, so the set cannot grow forever.
    if (this.reportedFlows.size > 500) this.reportedFlows.clear()
  }

  /// The keeper's key, if one was configured. The keeper alerts on this itself; the monitor
  /// repeats it because a keeper that is down cannot tell anyone it is down.
  private async checkKeeperGas() {
    if (!this.config.keeperAddress) return null
    const [balance, gasPrice] = await Promise.all([
      this.client.getBalance({ address: this.config.keeperAddress }),
      this.client.getGasPrice()
    ])
    const remaining = liquidationsAffordable(balance, gasPrice, 150_000n)
    log.info("keeper.gas", { address: this.config.keeperAddress, liquidationsRemaining: remaining })
    return remaining
  }

  // ----------------------------------------------------------------------------------------
  // the pass
  // ----------------------------------------------------------------------------------------

  async scanOnce(): Promise<Snapshot> {
    const pairs = await discoverPositions(
      this.client,
      this.config.poolAddress,
      this.config.deployBlock,
      this.config.logChunkBlocks
    )
    const snapshot = await readSnapshot(this.client, this.config.poolAddress, pairs)

    log.info("metrics", {
      block: snapshot.blockNumber,
      poolSize: usd(snapshot.poolSize),
      totalDebt: usd(snapshot.totalDebt),
      utilisation: pct(snapshot.utilisationBps),
      availableLiquidity: usd(snapshot.availableLiquidity),
      protocolFees: usd(snapshot.protocolFees),
      reserve: usd(snapshot.reserve),
      badDebt: usd(snapshot.badDebt),
      paused: pausedList(snapshot.pausedActions),
      openPositions: snapshot.positions.length,
      liquidatable: snapshot.positions.filter(p => p.liquidatable).length
    })

    for (const asset of snapshot.assets) {
      log.info("metrics.asset", {
        asset: asset.address,
        priceStatus: asset.priceStatus,
        oracleAgeSeconds: asset.oracleAgeSeconds,
        maxPriceAge: asset.maxPriceAge ?? "none",
        debt: usd(asset.debt),
        debtCap: asset.debtCap === 0n ? "uncapped" : usd(asset.debtCap)
      })
    }

    await this.checkUtilisation(snapshot)
    await this.checkPositions(snapshot)
    await this.checkOracles(snapshot)
    await this.checkFlows(snapshot)
    await this.checkKeeperGas()

    return snapshot
  }

  async watch() {
    log.info("monitor.start", {
      pool: this.config.poolAddress,
      rpc: this.config.rpcUrl,
      intervalMs: this.config.intervalMs
    })
    let failures = 0
    for (;;) {
      const startedAt = Date.now()
      try {
        await this.scanOnce()
        failures = 0
        log.info("scan.complete", { durationMs: Date.now() - startedAt })
      } catch (error) {
        failures += 1
        const why = reason(error)
        log.error("scan.failed", { reason: why, consecutive: failures })
        await this.alerter.fire({
          kind: "scan_failed",
          severity: failures >= 3 ? "critical" : "warning",
          key: "scan",
          message: `monitor pass failed ${failures} time(s) in a row: ${why}`,
          fields: { reason: why, consecutive: failures }
        })
      }
      const backoff = Math.min(failures, 5)
      await new Promise(resolve => setTimeout(resolve, this.config.intervalMs * (backoff > 0 ? 2 ** backoff : 1)))
    }
  }

  /// Fires one of every alert so the channel, the routing and the rotation can be tested without
  /// waiting for a real incident. Every alert in the table in README.md appears here.
  async drill() {
    log.info("drill.start", {})
    const alerts = [
      { kind: "utilisation_high", severity: "warning", message: "DRILL: utilisation above threshold" },
      { kind: "position_at_risk", severity: "warning", message: "DRILL: position liquidatable for several minutes" },
      { kind: "keeper_silent", severity: "critical", message: "DRILL: position liquidatable and nothing clearing it" },
      { kind: "stale_price", severity: "critical", message: "DRILL: the pool will not act on a price" },
      { kind: "large_flow", severity: "warning", message: "DRILL: single deposit large against the pool" },
      { kind: "scan_failed", severity: "critical", message: "DRILL: monitor pass failed" }
    ] as const
    for (const alert of alerts) {
      await this.alerter.fire({ ...alert, key: "drill", fields: { drill: true } })
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
const monitor = new Monitor(config, alerter)

if (!config.alerts.webhookUrl) {
  log.warn("alerts.no_webhook", { hint: "set ALERT_WEBHOOK_URL; alerts will only reach the log" })
}

process.on("unhandledRejection", error => {
  log.error("monitor.unhandled_rejection", { reason: reason(error) })
  process.exit(1)
})
process.on("uncaughtException", error => {
  log.error("monitor.uncaught_exception", { reason: reason(error) })
  process.exit(1)
})
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    log.info("monitor.stopping", { signal })
    process.exit(0)
  })
}

if (mode === "watch") {
  await monitor.watch()
} else if (mode === "drill") {
  const fired = await monitor.drill()
  if (fired === 0) {
    log.error("drill.nothing_fired", {})
    process.exit(1)
  }
} else {
  await monitor.scanOnce()
  log.info("scan.complete", {})
}
