/// Structured logging, because these lines are read by a log aggregator during an incident rather
/// than by a person watching a terminal. Set LOG_FORMAT=text for the human-readable form when
/// running locally.

export type Level = "info" | "warn" | "error"

const json = process.env.LOG_FORMAT !== "text"
let instance = "keeper"

export function setInstance(id: string) {
  instance = id
}

function emit(level: Level, event: string, fields: Record<string, unknown>) {
  const time = new Date().toISOString()
  if (json) {
    // BigInt does not survive JSON.stringify, and half the values here are chain values.
    const safe = Object.fromEntries(
      Object.entries(fields).map(([key, value]) => [key, typeof value === "bigint" ? value.toString() : value])
    )
    const line = JSON.stringify({ time, level, instance, event, ...safe })
    if (level === "error") console.error(line)
    else console.log(line)
    return
  }
  const rest = Object.entries(fields)
    .map(([key, value]) => `${key}=${value}`)
    .join(" ")
  const line = `[${time}] ${level.toUpperCase().padEnd(5)} ${event}${rest ? " " + rest : ""}`
  if (level === "error") console.error(line)
  else console.log(line)
}

export const log = {
  info: (event: string, fields: Record<string, unknown> = {}) => emit("info", event, fields),
  warn: (event: string, fields: Record<string, unknown> = {}) => emit("warn", event, fields),
  error: (event: string, fields: Record<string, unknown> = {}) => emit("error", event, fields)
}

/// Pulls the revert reason out of a viem error, which carries it a few lines into a long message.
/// Without this a log says a call reverted but never says why, which is the only useful part.
export function reason(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error)
  const reverted = text.match(/reverted with the following reason:\s*\n?\s*(.+)/)
  return (reverted?.[1] ?? text.split("\n")[0]).trim()
}
