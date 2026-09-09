import { decodeEventLog, getAddress, toEventSelector, type Address, type Log, type PublicClient } from "viem"
import type { Config } from "./config.ts"
import type { EventRow, PricePoint, Store } from "./db.ts"
import { ANSWER_UPDATED, INDEXED_EVENTS, type IndexedEvent } from "./events.ts"
import { Fold, persistPositions, rebuild } from "./fold.ts"
import { log, reason } from "./log.ts"

const signatureOf = (entry: IndexedEvent) =>
  `${entry.abi.name}(${entry.abi.inputs.map(input => input.type).join(",")})`

/// topic0 to the event it belongs to. Two contracts can emit the same signature — `OwnerChanged`
/// is on all three — so the address decides which source a log is attributed to, not the topic.
const SELECTORS = new Map<string, IndexedEvent[]>()
for (const entry of INDEXED_EVENTS) {
  const selector = toEventSelector(signatureOf(entry))
  const existing = SELECTORS.get(selector)
  if (existing) existing.push(entry)
  else SELECTORS.set(selector, [entry])
}

const ANSWER_UPDATED_SELECTOR = toEventSelector("AnswerUpdated(int256,uint256,uint256)")

const stringify = (value: unknown): string =>
  typeof value === "bigint" ? value.toString() : value === undefined || value === null ? "" : String(value)

export type SyncResult = {
  fromBlock: bigint
  toBlock: bigint
  events: number
  prices: number
  chunks: number
  rewound: boolean
}

export class Syncer {
  private readonly fold = new Fold()
  /// Feeds discovered from PriceFeedSet, so their own price history is indexed too. A feed the
  /// pool has never been pointed at is not this index's business.
  private readonly feeds = new Set<Address>()
  private foldPrimed = false

  constructor(
    private readonly config: Config,
    private readonly client: PublicClient,
    private readonly store: Store
  ) {}

  private get addresses(): Address[] {
    return [this.config.poolAddress, this.config.deskAddress, this.config.registryAddress].filter(
      (value): value is Address => value !== null
    )
  }

  /// Which source an address belongs to. Falls back to the feed bucket, because the only other
  /// addresses this indexer ever queries are the price feeds it discovered.
  private sourceOf(address: string): string {
    const normalised = getAddress(address)
    if (normalised === this.config.poolAddress) return "pool"
    if (this.config.deskAddress && normalised === this.config.deskAddress) return "desk"
    if (this.config.registryAddress && normalised === this.config.registryAddress) return "registry"
    return "feed"
  }

  /// Restores the fold from what is already stored, so a restart continues rather than
  /// recomputing from zero on every pass. Cheap: the event table holds the protocol's events, not
  /// the chain's blocks.
  private primeFold() {
    if (this.foldPrimed) return
    const events = this.store.allEventsInOrder()
    this.fold.apply(events)
    for (const event of events) {
      if (event.name === "PriceFeedSet" && event.args.feed && !/^0x0+$/.test(event.args.feed)) {
        this.feeds.add(getAddress(event.args.feed))
      }
    }
    this.foldPrimed = true
    log.info("fold.primed", { events: events.length, deposits: this.fold.pool.deposits, debt: this.fold.pool.debt })
  }

  /// One pass. Reads from wherever the cursor left off, minus the reorg window, up to the head.
  async syncOnce(): Promise<SyncResult> {
    this.primeFold()

    const head = await this.client.getBlockNumber()
    const stored = this.store.lastBlock()

    // Everything within the reorg window is re-read every pass. The rows are keyed by block and
    // log index, so a re-read that finds the same logs is a no-op, and one that finds different
    // logs replaces them.
    const unstableFrom = head > this.config.reorgDepthBlocks ? head - this.config.reorgDepthBlocks : 0n
    let fromBlock = stored === null ? this.config.deployBlock : stored + 1n
    let rewound = false
    if (stored !== null && unstableFrom < fromBlock) {
      const target = unstableFrom < this.config.deployBlock ? this.config.deployBlock : unstableFrom
      if (target < fromBlock) {
        this.store.rewindTo(target)
        this.foldPrimed = false
        this.fold.pool = { deposits: 0n, debt: 0n }
        this.fold.positions.clear()
        this.primeFold()
        fromBlock = target
        rewound = true
      }
    }
    if (fromBlock < this.config.deployBlock) fromBlock = this.config.deployBlock
    if (fromBlock > head) return { fromBlock, toBlock: head, events: 0, prices: 0, chunks: 0, rewound }

    const { logs, chunks } = await this.fetchLogs(this.addresses, fromBlock, head, [...SELECTORS.keys()])

    // Feeds are discovered from the pool's own PriceFeedSet history, which may be in this very
    // batch. Their price logs are fetched in a second pass so a feed configured moments ago still
    // has its history indexed on the same run.
    for (const entry of logs) {
      if (entry.topics[0] !== toEventSelector("PriceFeedSet(address,address)")) continue
      const feed = getAddress(`0x${entry.topics[2]!.slice(26)}` as Address)
      if (!/^0x0+$/.test(feed)) this.feeds.add(feed)
    }

    let priceLogs: Log[] = []
    let priceChunks = 0
    if (this.feeds.size > 0) {
      // A feed's history predates the pool being pointed at it, and a liquidation can only be
      // priced against a round that already existed. Reading from the deploy block would leave
      // the timeline starting after the first liquidation it has to explain.
      const priceFrom = rewound || stored === null ? 0n : fromBlock
      const fetched = await this.fetchLogs([...this.feeds], priceFrom, head, [ANSWER_UPDATED_SELECTOR])
      priceLogs = fetched.logs
      priceChunks = fetched.chunks
    }

    // Only the protocol's logs need a block timestamp. A price point carries `updatedAt` in the
    // event itself — the round's own time, which is the one that matters for a price — so asking
    // the node for those blocks would be several hundred requests for a column nothing reads.
    const timestamps = await this.fetchTimestamps(logs)
    const events = this.decodeEvents(logs, timestamps)
    const prices = this.decodePrices(priceLogs)

    this.store.writeBatch(events, prices, head)

    // The fold runs after the write so that a crash between the two loses derived rows, which are
    // rebuilt from the events, rather than events, which cannot be.
    if (rewound) {
      const refolded = rebuild(this.store)
      this.fold.pool = refolded.pool
      this.fold.positions.clear()
      for (const [id, position] of refolded.positions) this.fold.positions.set(id, position)
    } else {
      const points = this.fold.apply(events)
      for (const point of points) {
        this.store.writePoolPoint(point.blockNumber, point.logIndex, point.timestamp, point.state.deposits, point.state.debt)
      }
      persistPositions(this.store, this.fold)
    }

    await this.learnFeedDecimals()

    return { fromBlock, toBlock: head, events: events.length, prices: prices.length, chunks: chunks + priceChunks, rewound }
  }

  /// getLogs, sized by the node's own limit rather than by a guess at it.
  ///
  /// The measured cap on this chain is **10,000 matched logs**, not a block range — a query over
  /// the whole chain is accepted if few enough logs match it. That distinction decides the shape
  /// of this loop. A fixed block span would be the wrong unit twice over: at 689,000 blocks a day
  /// a span small enough for a busy contract means thousands of calls for a sparse one, and the
  /// first sync of a price feed with 483 logs in it would take half an hour.
  ///
  /// So the span starts at the whole remaining range and halves only when the node objects,
  /// doubling back up after a chunk it accepted. It converges on whatever the chain is actually
  /// doing rather than on what the configuration assumed.
  private async fetchLogs(
    addresses: Address[],
    fromBlock: bigint,
    toBlock: bigint,
    topics: string[]
  ): Promise<{ logs: Log[]; chunks: number }> {
    if (addresses.length === 0 || fromBlock > toBlock) return { logs: [], chunks: 0 }
    const collected: Log[] = []
    const ceiling = this.config.logChunkBlocks
    let chunks = 0
    let cursor = fromBlock
    let span = toBlock - fromBlock + 1n
    if (span > ceiling) span = ceiling

    while (cursor <= toBlock) {
      const remaining = toBlock - cursor + 1n
      const attempt = span > remaining ? remaining : span
      const end = cursor + attempt - 1n
      try {
        const batch = (await this.client.request({
          method: "eth_getLogs",
          params: [
            {
              address: addresses.map(value => value.toLowerCase()) as Address[],
              topics: [topics as `0x${string}`[]],
              fromBlock: `0x${cursor.toString(16)}`,
              toBlock: `0x${end.toString(16)}`
            }
          ]
        } as never)) as Log[]
        collected.push(...batch)
        chunks += 1
        cursor = end + 1n
        // Widen again after a chunk the node accepted, so one dense stretch does not slow the
        // rest of the range down behind it.
        if (span < ceiling) span = span * 2n > ceiling ? ceiling : span * 2n
      } catch (error) {
        const message = reason(error)
        const tooMany = /exceeds limit|too many|query returned more than|response size|limit exceeded/i.test(message)
        if (!tooMany || attempt <= 1n) throw error
        span = attempt / 2n > 0n ? attempt / 2n : 1n
        log.warn("logs.narrowed", { span, from: cursor, reason: message })
      }
    }
    return { logs: collected, chunks }
  }

  /// Block timestamps, for the blocks that actually carry an event.
  ///
  /// This is the whole reason a log-driven index is affordable here. Walking the chain would cost
  /// one request per block, and this chain produces around 689,000 blocks a day; asking only for
  /// the blocks that emitted something costs one request per event-carrying block, of which there
  /// are a handful. The requests are batched at the node's measured limit of 100.
  private async fetchTimestamps(logs: Log[]): Promise<Map<bigint, number>> {
    const wanted = [...new Set(logs.map(entry => entry.blockNumber).filter((value): value is bigint => value !== null))]
    const timestamps = new Map<bigint, number>()
    for (let index = 0; index < wanted.length; index += this.config.timestampBatchSize) {
      const slice = wanted.slice(index, index + this.config.timestampBatchSize)
      const blocks = await Promise.all(
        slice.map(number =>
          this.client
            .getBlock({ blockNumber: number, includeTransactions: false })
            .then(block => ({ number, timestamp: Number(block.timestamp) }))
            .catch(error => {
              // A block the node will not serve costs its rows their date and nothing else. The
              // amounts, the addresses and the ordering are all in the log itself.
              log.warn("timestamp.unavailable", { block: number, reason: reason(error) })
              return null
            })
        )
      )
      for (const entry of blocks) if (entry) timestamps.set(entry.number, entry.timestamp)
    }
    return timestamps
  }

  private decodeEvents(logs: Log[], timestamps: Map<bigint, number>): EventRow[] {
    const rows: EventRow[] = []
    for (const entry of logs) {
      if (entry.blockNumber === null || entry.logIndex === null) continue
      const selector = entry.topics[0]
      if (!selector) continue
      const candidates = SELECTORS.get(selector)
      if (!candidates) continue
      const source = this.sourceOf(entry.address)
      // The same signature can exist on two contracts. The address settles which definition to
      // decode with, and a log from a contract that does not declare this event is skipped rather
      // than decoded against the wrong shape.
      const definition = candidates.find(candidate => candidate.source === source)
      if (!definition) continue

      let decoded: { args: Record<string, unknown> }
      try {
        decoded = decodeEventLog({
          abi: [definition.abi],
          data: entry.data,
          topics: entry.topics as [signature: `0x${string}`, ...args: `0x${string}`[]]
        }) as { args: Record<string, unknown> }
      } catch (error) {
        log.warn("decode.failed", { name: definition.abi.name, tx: entry.transactionHash, reason: reason(error) })
        continue
      }

      const args: Record<string, string> = {}
      for (const [name, value] of Object.entries(decoded.args ?? {})) args[name] = stringify(value)

      const actor = definition.actorArg ? (args[definition.actorArg] ?? null) : null
      const asset = definition.assetArg ? (args[definition.assetArg] ?? null) : null

      rows.push({
        blockNumber: entry.blockNumber,
        logIndex: entry.logIndex,
        txHash: entry.transactionHash ?? "",
        timestamp: timestamps.get(entry.blockNumber) ?? null,
        source: definition.source,
        address: getAddress(entry.address),
        name: definition.abi.name!,
        // Addresses are stored lower-cased so a query never depends on the caller getting the
        // checksum right. The chain does not care and neither should a lookup.
        actor: actor ? actor.toLowerCase() : null,
        asset: asset ? asset.toLowerCase() : null,
        args
      })
    }
    // Chain order, because the fold depends on it.
    return rows.sort((a, b) =>
      a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1
    )
  }

  private decodePrices(logs: Log[]): PricePoint[] {
    const points: PricePoint[] = []
    for (const entry of logs) {
      if (entry.blockNumber === null || entry.logIndex === null) continue
      if (entry.topics[0] !== ANSWER_UPDATED_SELECTOR) continue
      try {
        const decoded = decodeEventLog({
          abi: [ANSWER_UPDATED],
          data: entry.data,
          topics: entry.topics as [signature: `0x${string}`, ...args: `0x${string}`[]]
        }) as { args: { current: bigint; roundId: bigint; updatedAt: bigint } }
        points.push({
          feed: getAddress(entry.address),
          blockNumber: entry.blockNumber,
          logIndex: entry.logIndex,
          updatedAt: Number(decoded.args.updatedAt),
          answer: decoded.args.current.toString()
        })
      } catch (error) {
        log.warn("price.decode_failed", { tx: entry.transactionHash, reason: reason(error) })
      }
    }
    return points
  }

  /// A feed's decimals are needed to turn its answer into a price, and they never change. Read
  /// once per feed and stored, so a history query is served from the file alone.
  private async learnFeedDecimals() {
    for (const feed of this.feeds) {
      if (this.store.feedMeta(feed)) continue
      try {
        const [decimals, description] = await Promise.all([
          this.client.readContract({
            abi: [{ type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] }],
            address: feed,
            functionName: "decimals"
          }) as Promise<number>,
          this.client
            .readContract({
              abi: [
                { type: "function", name: "description", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] }
              ],
              address: feed,
              functionName: "description"
            })
            .catch(() => null) as Promise<string | null>
        ])
        this.store.setFeedMeta(feed, Number(decimals), description)
        log.info("feed.learned", { feed, decimals: Number(decimals), description })
      } catch (error) {
        log.warn("feed.unreadable", { feed, reason: reason(error) })
      }
    }
  }
}
