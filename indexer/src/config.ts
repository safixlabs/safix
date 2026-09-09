import { readFileSync } from "node:fs"
import { getAddress, isAddress } from "viem"

/// Everything the indexer needs, after validation. Anything optional in the file has a value
/// here, so nothing downstream branches on "was this configured".
export type Config = {
  rpcUrl: string
  poolAddress: `0x${string}`
  /// The desk and the registry are optional: a deployment can run the pool alone, and an index
  /// that refused to start without them would be harder to operate for no gain.
  deskAddress: `0x${string}` | null
  registryAddress: `0x${string}` | null
  deployBlock: bigint
  intervalMs: number
  databasePath: string
  /// Where the read API listens. The API serves reads only and holds no key.
  port: number
  /// Ceiling on the block span one getLogs call may cover. The sync starts at the whole
  /// remaining range and only narrows when the node objects, so this is a safety rail rather
  /// than a tuning knob — the real limit on this chain is 10,000 matched logs, not blocks.
  logChunkBlocks: bigint
  /// How many blocks back from the head are treated as still able to change. Rows at or above
  /// head minus this are re-read every pass, so a reorg is corrected rather than remembered.
  reorgDepthBlocks: bigint
  /// Block timestamps are fetched in batches of this size. The public node rejects a JSON-RPC
  /// batch larger than 100, measured; see README.md.
  timestampBatchSize: number
  instanceId: string
}

const DEFAULTS = {
  intervalMs: 20_000,
  databasePath: "./safix-index.db",
  port: 8080,
  // Effectively "the whole chain": the node has no block-range cap, only a log-count one.
  logChunkBlocks: 200_000_000n,
  // The node reports `finalized` about 9,500 blocks behind the head, which at this chain's
  // measured 0.125s blocks is around twenty minutes. Re-reading a slightly wider window costs one
  // getLogs call per pass and removes the question entirely.
  reorgDepthBlocks: 12_000n,
  timestampBatchSize: 100
}

const fail = (message: string): never => {
  throw new Error(`config: ${message}`)
}

const optionalAddress = (value: unknown, name: string): `0x${string}` | null => {
  if (value === undefined || value === null || value === "") return null
  const text = String(value)
  if (!isAddress(text)) fail(`${name} is not an address`)
  if (/^0x0+$/.test(text)) return null
  return getAddress(text)
}

/// Reads the config file and the environment, and refuses to start on anything it cannot trust.
/// An index that boots with a half-valid config is worse than one that does not boot: it looks
/// like it is following the chain.
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

  const positive = (value: unknown, fallback: number, name: string) => {
    if (value === undefined) return fallback
    const parsed = Number(value)
    if (!Number.isFinite(parsed) || parsed <= 0) fail(`${name} must be a positive number`)
    return parsed
  }

  const timestampBatchSize = positive(raw.timestampBatchSize, DEFAULTS.timestampBatchSize, "timestampBatchSize")
  if (timestampBatchSize > 100) {
    fail("timestampBatchSize must be 100 or less; the node rejects a larger JSON-RPC batch with 429")
  }

  const port = positive(env.PORT ?? raw.port, DEFAULTS.port, "port")
  if (!Number.isInteger(port) || port > 65535) fail("port must be an integer below 65536")

  return {
    rpcUrl,
    poolAddress: getAddress(poolAddress),
    deskAddress: optionalAddress(raw.deskAddress, "deskAddress"),
    registryAddress: optionalAddress(raw.registryAddress, "registryAddress"),
    deployBlock: BigInt(Math.max(0, Number(raw.deployBlock ?? 0))),
    intervalMs: positive(raw.intervalMs, DEFAULTS.intervalMs, "intervalMs"),
    databasePath: String(env.DATABASE_PATH ?? raw.databasePath ?? DEFAULTS.databasePath),
    port,
    logChunkBlocks: BigInt(positive(raw.logChunkBlocks, Number(DEFAULTS.logChunkBlocks), "logChunkBlocks")),
    reorgDepthBlocks: BigInt(positive(raw.reorgDepthBlocks, Number(DEFAULTS.reorgDepthBlocks), "reorgDepthBlocks")),
    timestampBatchSize,
    instanceId: String(env.INSTANCE_ID ?? raw.instanceId ?? "indexer")
  }
}
