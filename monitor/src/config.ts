import { readFileSync } from "node:fs"
import { getAddress, isAddress } from "viem"

/// The monitor holds no key. It reads the chain and sends alerts, and that is all it can do —
/// which is the point: the thing watching the protocol should not be able to move it.
export type Config = {
  rpcUrl: string
  poolAddress: `0x${string}`
  deployBlock: bigint
  intervalMs: number
  logChunkBlocks: bigint
  instanceId: string
  /// Optional. When set, the monitor reports whether the keeper's key can still pay for gas.
  keeperAddress: `0x${string}` | null
  alerts: {
    webhookUrl: string | null
    cooldownMs: number
  }
  thresholds: {
    /// Utilisation, in basis points, above which the pool is too lent out to absorb a liquidation
    /// and let providers leave at the same time.
    utilisationBps: number
    /// A position may sit liquidatable this long before it is worth waking someone.
    positionAtRiskSeconds: number
    /// Longer than that, and the conclusion is not "a position is unhealthy" but "nothing is
    /// liquidating it", which is a different problem with a different fix.
    keeperSilentSeconds: number
    /// A price older than its own guard is already refused by the pool; this fires earlier, while
    /// there is still time to look at the feed.
    oracleAgeWarningRatio: number
    /// A single deposit or withdrawal larger than this share of the pool, in basis points.
    largeFlowBps: number
    /// How far back to look for those movements.
    flowWindowBlocks: bigint
  }
}

const DEFAULTS = {
  intervalMs: 60_000,
  logChunkBlocks: 50_000n,
  cooldownMs: 15 * 60_000,
  utilisationBps: 8_000,
  positionAtRiskSeconds: 300,
  keeperSilentSeconds: 900,
  oracleAgeWarningRatio: 0.8,
  largeFlowBps: 1_000,
  flowWindowBlocks: 5_000n
}

const fail = (message: string): never => {
  throw new Error(`config: ${message}`)
}

export function loadConfig(path: string, env: NodeJS.ProcessEnv = process.env): Config {
  let raw: Record<string, unknown>
  try {
    raw = JSON.parse(readFileSync(path, "utf8"))
  } catch (error) {
    return fail(`cannot read ${path}: ${error instanceof Error ? error.message : String(error)}`)
  }

  const rpcUrl = String(env.RPC_URL ?? raw.rpcUrl ?? "")
  if (!/^https?:\/\//.test(rpcUrl)) fail("rpcUrl must be an http(s) URL")

  const poolAddress = String(raw.poolAddress ?? "")
  if (!isAddress(poolAddress)) fail("poolAddress is not an address")
  if (/^0x0+$/.test(poolAddress)) fail("poolAddress is the zero address")

  const keeper = raw.keeperAddress ? String(raw.keeperAddress) : null
  if (keeper && !isAddress(keeper)) fail("keeperAddress is not an address")

  const t = (raw.thresholds ?? {}) as Record<string, unknown>
  const alerts = (raw.alerts ?? {}) as Record<string, unknown>

  const positive = (value: unknown, fallback: number, name: string) => {
    if (value === undefined) return fallback
    const parsed = Number(value)
    if (!Number.isFinite(parsed) || parsed <= 0) fail(`${name} must be a positive number`)
    return parsed
  }

  const utilisationBps = positive(t.utilisationBps, DEFAULTS.utilisationBps, "thresholds.utilisationBps")
  if (utilisationBps > 10_000) fail("thresholds.utilisationBps cannot exceed 10000")

  const positionAtRiskSeconds = positive(
    t.positionAtRiskSeconds,
    DEFAULTS.positionAtRiskSeconds,
    "thresholds.positionAtRiskSeconds"
  )
  const keeperSilentSeconds = positive(t.keeperSilentSeconds, DEFAULTS.keeperSilentSeconds, "thresholds.keeperSilentSeconds")
  if (keeperSilentSeconds <= positionAtRiskSeconds) {
    // Otherwise the two alerts fire together and the second one says nothing the first did not.
    fail("thresholds.keeperSilentSeconds must be greater than thresholds.positionAtRiskSeconds")
  }

  const ratio = positive(t.oracleAgeWarningRatio, DEFAULTS.oracleAgeWarningRatio, "thresholds.oracleAgeWarningRatio")
  if (ratio >= 1) fail("thresholds.oracleAgeWarningRatio must be below 1, or it fires no earlier than the pool's own refusal")

  return {
    rpcUrl,
    poolAddress: getAddress(poolAddress),
    deployBlock: BigInt(Math.max(0, Number(raw.deployBlock ?? 0))),
    intervalMs: positive(raw.intervalMs, DEFAULTS.intervalMs, "intervalMs"),
    logChunkBlocks: BigInt(positive(raw.logChunkBlocks, Number(DEFAULTS.logChunkBlocks), "logChunkBlocks")),
    instanceId: String(env.INSTANCE_ID ?? raw.instanceId ?? "monitor"),
    keeperAddress: keeper ? getAddress(keeper) : null,
    alerts: {
      // A secret, so it comes from the host's store rather than a file that gets committed.
      webhookUrl: env.ALERT_WEBHOOK_URL ?? null,
      cooldownMs: positive(alerts.cooldownMs, DEFAULTS.cooldownMs, "alerts.cooldownMs")
    },
    thresholds: {
      utilisationBps,
      positionAtRiskSeconds,
      keeperSilentSeconds,
      oracleAgeWarningRatio: ratio,
      largeFlowBps: positive(t.largeFlowBps, DEFAULTS.largeFlowBps, "thresholds.largeFlowBps"),
      flowWindowBlocks: BigInt(positive(t.flowWindowBlocks, Number(DEFAULTS.flowWindowBlocks), "thresholds.flowWindowBlocks"))
    }
  }
}
