import { log } from "./log.ts"

/// The four things worth waking someone for, and nothing else. An alert that fires on something
/// nobody acts on trains people to ignore the channel, which costs more than the alert saved.
export type AlertKind =
  /// A scan failed outright: the RPC is unreachable, or something threw where nothing should.
  | "scan_failed"
  /// A transaction reverted for a reason that is not another keeper getting there first.
  | "tx_reverted"
  /// A position has been liquidatable across several consecutive scans and is still there.
  | "position_stuck"
  /// The keeper's key is running out of gas, with enough warning to top it up.
  | "gas_low"

export type Severity = "warning" | "critical"

export type Alert = {
  kind: AlertKind
  severity: Severity
  /// Distinguishes one instance of a kind from another, so a stuck position on asset A does not
  /// silence one on asset B. Alerts are deduplicated on kind plus key.
  key: string
  message: string
  fields?: Record<string, unknown>
}

export type Alerter = {
  fire: (alert: Alert) => Promise<void>
  /// Test-only view of what has been sent, used by the drill to assert delivery.
  sent: Alert[]
}

/// Sends alerts to a webhook, with a cooldown per kind+key so an ongoing incident does not become
/// a flood. Delivery failures are logged and swallowed: a keeper that dies because its alerting is
/// down is strictly worse than one that keeps liquidating quietly.
export function createAlerter(webhookUrl: string | null, cooldownMs: number, instanceId: string): Alerter {
  const lastSentAt = new Map<string, number>()
  const sent: Alert[] = []

  async function fire(alert: Alert) {
    const dedupeKey = `${alert.kind}:${alert.key}`
    const now = Date.now()
    const previous = lastSentAt.get(dedupeKey)
    if (previous !== undefined && now - previous < cooldownMs) {
      log.info("alert.suppressed", { kind: alert.kind, key: alert.key, sinceMs: now - previous })
      return
    }
    lastSentAt.set(dedupeKey, now)
    sent.push(alert)

    const level = alert.severity === "critical" ? log.error : log.warn
    level(`alert.${alert.kind}`, { severity: alert.severity, key: alert.key, message: alert.message, ...alert.fields })

    if (!webhookUrl) return

    // A shape both Slack and Discord accept, so the channel is a configuration choice rather than
    // a code change.
    const emoji = alert.severity === "critical" ? "🚨" : "⚠️"
    const details = Object.entries(alert.fields ?? {})
      .map(([key, value]) => `${key}: ${value}`)
      .join("\n")
    const body = {
      content: `${emoji} **safix keeper / ${instanceId}** — ${alert.kind}\n${alert.message}${details ? "\n```\n" + details + "\n```" : ""}`,
      text: `${emoji} safix keeper / ${instanceId} — ${alert.kind}: ${alert.message}${details ? "\n" + details : ""}`
    }

    try {
      const response = await fetch(webhookUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10_000)
      })
      if (!response.ok) {
        log.error("alert.delivery_failed", { kind: alert.kind, status: response.status })
      }
    } catch (error) {
      log.error("alert.delivery_failed", {
        kind: alert.kind,
        error: error instanceof Error ? error.message : String(error)
      })
    }
  }

  return { fire, sent }
}

/// Turns a balance into the number of liquidations it can still pay for, which is the unit an
/// on-call engineer can act on. "0.004 ETH" means nothing at 3am; "12 liquidations left" does.
export function liquidationsAffordable(balanceWei: bigint, gasPriceWei: bigint, liquidationGas: bigint): number {
  const costPerLiquidation = gasPriceWei * liquidationGas
  if (costPerLiquidation === 0n) return Number.MAX_SAFE_INTEGER
  return Number(balanceWei / costPerLiquidation)
}
