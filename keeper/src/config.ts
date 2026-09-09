import { readFileSync } from "node:fs"
import { getAddress, isAddress } from "viem"

/// Everything the keeper needs to run, after validation. Anything optional in the file has a
/// value here, so the rest of the code never branches on "was this configured".
export type Config = {
  rpcUrl: string
  poolAddress: `0x${string}`
  deployBlock: bigint
  intervalMs: number
  /// Manual prices for assets with no Chainlink feed, as address to USD price.
  prices: Record<`0x${string}`, number>
  /// Largest block span a single getLogs call may cover. Public RPCs cap this.
  logChunkBlocks: bigint
  instanceId: string
  alerts: {
    webhookUrl: string | null
    /// How long the same alert stays quiet after firing, so an incident does not become a flood.
    cooldownMs: number
    /// Consecutive scans a position may stay liquidatable before it is treated as stuck.
    stuckScans: number
  }
  gas: {
    /// Balance below which the keeper warns, expressed as liquidations it can still afford.
    warnLiquidations: number
    /// Balance below which it escalates. The gap between the two is the time to act.
    criticalLiquidations: number
    /// Gas one liquidation costs, used to turn a balance into a number of liquidations.
    liquidationGas: bigint
  }
}

const DEFAULTS = {
  intervalMs: 15_000,
  logChunkBlocks: 50_000n,
  alerts: { cooldownMs: 15 * 60_000, stuckScans: 3 },
  // Measured from testnet liquidations, which land between 100k and 120k gas.
  gas: { warnLiquidations: 200, criticalLiquidations: 50, liquidationGas: 150_000n }
}

const fail = (message: string): never => {
  throw new Error(`config: ${message}`)
}

/// Reads the config file and the environment, and refuses to start on anything it cannot trust.
/// A keeper that boots with a half-valid config is worse than one that does not boot: it looks
/// like it is watching the pool.
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

  const alerts = (raw.alerts ?? {}) as Record<string, unknown>
  const gas = (raw.gas ?? {}) as Record<string, unknown>

  const positive = (value: unknown, fallback: number, name: string) => {
    if (value === undefined) return fallback
    const parsed = Number(value)
    if (!Number.isFinite(parsed) || parsed <= 0) fail(`${name} must be a positive number`)
    return parsed
  }

  const prices: Record<`0x${string}`, number> = {}
  for (const [asset, price] of Object.entries((raw.prices ?? {}) as Record<string, unknown>)) {
    if (!isAddress(asset)) fail(`prices contains a non-address key: ${asset}`)
    const parsed = Number(price)
    if (!Number.isFinite(parsed) || parsed <= 0) fail(`price for ${asset} must be a positive number`)
    prices[getAddress(asset)] = parsed
  }

  const warnLiquidations = positive(gas.warnLiquidations, DEFAULTS.gas.warnLiquidations, "gas.warnLiquidations")
  const criticalLiquidations = positive(
    gas.criticalLiquidations,
    DEFAULTS.gas.criticalLiquidations,
    "gas.criticalLiquidations"
  )
  if (criticalLiquidations >= warnLiquidations) {
    fail("gas.criticalLiquidations must be below gas.warnLiquidations, or the warning never fires first")
  }

  return {
    rpcUrl,
    poolAddress: getAddress(poolAddress),
    deployBlock: BigInt(Math.max(0, Number(raw.deployBlock ?? 0))),
    intervalMs: positive(raw.intervalMs, DEFAULTS.intervalMs, "intervalMs"),
    prices,
    logChunkBlocks: BigInt(positive(raw.logChunkBlocks, Number(DEFAULTS.logChunkBlocks), "logChunkBlocks")),
    // Distinguishes instances in logs and alerts when more than one keeper is running.
    instanceId: String(env.INSTANCE_ID ?? raw.instanceId ?? "keeper"),
    alerts: {
      // The URL is a secret and belongs in the host's secret store, never in the config file.
      webhookUrl: env.ALERT_WEBHOOK_URL ?? null,
      cooldownMs: positive(alerts.cooldownMs, DEFAULTS.alerts.cooldownMs, "alerts.cooldownMs"),
      stuckScans: positive(alerts.stuckScans, DEFAULTS.alerts.stuckScans, "alerts.stuckScans")
    },
    gas: {
      warnLiquidations,
      criticalLiquidations,
      liquidationGas: BigInt(positive(gas.liquidationGas, Number(DEFAULTS.gas.liquidationGas), "gas.liquidationGas"))
    }
  }
}

/// The private key, from the environment only. It is never read from the config file, so a config
/// can be committed, logged or shared without carrying the key with it.
export function loadPrivateKey(env: NodeJS.ProcessEnv = process.env): `0x${string}` {
  const key = env.PRIVATE_KEY
  if (!key) throw new Error("PRIVATE_KEY is required and must come from the environment")
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) throw new Error("PRIVATE_KEY is not a 32-byte hex key")
  return key as `0x${string}`
}
