import { createServer, type IncomingMessage, type ServerResponse } from "node:http"
import { isAddress } from "viem"
import type { Config } from "./config.ts"
import type { Store } from "./db.ts"
import { log } from "./log.ts"
import {
  actionHistory,
  attestationHistory,
  liquidations,
  partnershipHistory,
  poolHistory,
  positionHistory,
  positions,
  priceHistory
} from "./queries.ts"

/// The read API. Every route is a GET, there is no write path, and the process holds no key —
/// there is nowhere in the config to put one. A fully compromised index costs a wrong number on
/// a history screen, and the app falls back to the chain the moment it stops answering.
///
/// CORS is open because every row served here is already public in the chain's logs. The index
/// makes them fast to read; it does not make them visible.

const MAX_LIMIT = 500
const DEFAULT_LIMIT = 100

export type Health = {
  /// Head as of the last completed pass, and how far behind it the index was.
  head: bigint | null
  lastPassAt: number | null
  lastError: string | null
}

const json = (response: ServerResponse, status: number, body: unknown) => {
  const payload = JSON.stringify(body, null, 2)
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, OPTIONS",
    // The index is a cache of the chain; a stale answer for a few seconds is correct behaviour,
    // and this keeps a history screen from hammering it on every render.
    "cache-control": "public, max-age=5"
  })
  response.end(payload)
}

const limitOf = (params: URLSearchParams): number => {
  const raw = Number(params.get("limit") ?? DEFAULT_LIMIT)
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_LIMIT
  return Math.min(Math.floor(raw), MAX_LIMIT)
}

export function createApi(config: Config, store: Store, health: () => Health) {
  const handle = (request: IncomingMessage, response: ServerResponse) => {
    if (request.method === "OPTIONS") {
      response.writeHead(204, {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, OPTIONS",
        "access-control-max-age": "86400"
      })
      response.end()
      return
    }
    if (request.method !== "GET") return json(response, 405, { error: "read only" })

    const url = new URL(request.url ?? "/", "http://localhost")
    const path = url.pathname.replace(/\/+$/, "") || "/"
    const params = url.searchParams
    const limit = limitOf(params)
    const state = health()

    try {
      // --- liveness -------------------------------------------------------------------------
      // Deliberately trivial. It answers whether the process is up, which is what a restart
      // policy needs; whether it is current is /status, and conflating the two makes a host kill
      // an index that is merely behind.
      if (path === "/health") return json(response, 200, { ok: true, instance: config.instanceId })

      if (path === "/status") {
        const cursor = store.lastBlock()
        const counts = store.counts()
        const behind = state.head !== null && cursor !== null ? Number(state.head - cursor) : null
        return json(response, 200, {
          instance: config.instanceId,
          pool: config.poolAddress,
          desk: config.deskAddress,
          registry: config.registryAddress,
          deployBlock: Number(config.deployBlock),
          cursor: cursor === null ? null : Number(cursor),
          head: state.head === null ? null : Number(state.head),
          blocksBehind: behind,
          lastPassAt: state.lastPassAt,
          lastError: state.lastError,
          ...counts
        })
      }

      // --- the keeper's read ------------------------------------------------------------------
      if (path === "/positions") {
        return json(response, 200, positions(store, params.get("open") !== "false"))
      }

      if (path === "/pool/history") return json(response, 200, poolHistory(store, limit))

      if (path === "/liquidations") return json(response, 200, liquidations(store, limit))

      if (path === "/partnerships") return json(response, 200, partnershipHistory(store, params.get("id"), limit))

      // --- per-address ------------------------------------------------------------------------
      const history = path.match(/^\/history\/(0x[0-9a-fA-F]{40})$/)
      if (history) {
        const beforeRaw = params.get("before")
        const before = beforeRaw && /^\d+$/.test(beforeRaw) ? BigInt(beforeRaw) : null
        return json(response, 200, actionHistory(store, history[1], limit, before))
      }

      const position = path.match(/^\/position\/(0x[0-9a-fA-F]{40})\/(0x[0-9a-fA-F]{40})$/)
      if (position) return json(response, 200, positionHistory(store, position[1], position[2], limit))

      const attestations = path.match(/^\/attestations\/(0x[0-9a-fA-F]{40})$/)
      if (attestations) return json(response, 200, attestationHistory(store, attestations[1], limit))

      const prices = path.match(/^\/prices\/(0x[0-9a-fA-F]{40})$/)
      if (prices) {
        if (!isAddress(prices[1])) return json(response, 400, { error: "not an address" })
        return json(response, 200, priceHistory(store, prices[1], limit))
      }

      return json(response, 404, {
        error: "no such route",
        routes: [
          "/health",
          "/status",
          "/positions?open=true",
          "/pool/history?limit=",
          "/liquidations?limit=",
          "/partnerships?id=",
          "/history/:address?limit=&before=",
          "/position/:borrower/:asset",
          "/attestations/:address",
          "/prices/:feed"
        ]
      })
    } catch (error) {
      // A query that throws is this service's problem, not the caller's, and it must not take the
      // process down: the sync loop is in the same process and has to keep running.
      const message = error instanceof Error ? error.message : String(error)
      log.error("api.failed", { path, reason: message })
      return json(response, 500, { error: "query failed" })
    }
  }

  return createServer(handle)
}
