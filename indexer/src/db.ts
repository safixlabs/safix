import { DatabaseSync } from "node:sqlite"

/// SQLite, from Node's own standard library. No driver, no server, no migration tool.
///
/// The index is small by construction — it holds the protocol's events, which number in the
/// thousands, not the chain's blocks, which number in the hundreds of millions. A single file
/// that can be copied, inspected with the `sqlite3` binary and deleted to force a resync is worth
/// more here than anything that needs to be running before the indexer can start.

export type EventRow = {
  blockNumber: bigint
  logIndex: number
  txHash: string
  timestamp: number | null
  source: string
  address: string
  name: string
  actor: string | null
  asset: string | null
  /// The decoded arguments, with every bigint as a decimal string. JSON cannot carry a bigint and
  /// a uint256 does not fit a double, so the string is the only lossless form.
  args: Record<string, string>
}

export type PricePoint = {
  feed: string
  blockNumber: bigint
  logIndex: number
  updatedAt: number
  /// Raw feed answer, in the feed's own decimals. Scaling belongs where the decimals are known.
  answer: string
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS event (
  block_number INTEGER NOT NULL,
  log_index    INTEGER NOT NULL,
  tx_hash      TEXT    NOT NULL,
  timestamp    INTEGER,
  source       TEXT    NOT NULL,
  address      TEXT    NOT NULL,
  name         TEXT    NOT NULL,
  actor        TEXT,
  asset        TEXT,
  args         TEXT    NOT NULL,
  PRIMARY KEY (block_number, log_index)
);
CREATE INDEX IF NOT EXISTS event_actor  ON event(actor, block_number DESC, log_index DESC);
CREATE INDEX IF NOT EXISTS event_name   ON event(name, block_number DESC, log_index DESC);
CREATE INDEX IF NOT EXISTS event_source ON event(source, block_number DESC, log_index DESC);

CREATE TABLE IF NOT EXISTS price (
  feed         TEXT    NOT NULL,
  block_number INTEGER NOT NULL,
  log_index    INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  answer       TEXT    NOT NULL,
  PRIMARY KEY (feed, block_number, log_index)
);
CREATE INDEX IF NOT EXISTS price_feed ON price(feed, block_number DESC, log_index DESC);

CREATE TABLE IF NOT EXISTS feed_meta (
  feed        TEXT PRIMARY KEY,
  decimals    INTEGER NOT NULL,
  description TEXT
);

-- Pool size and debt after every event that moved either. Folded from the events rather than
-- read from the chain, because the node keeps state for about thirteen minutes and this has to
-- answer for the whole history. 'reconcile' checks the fold against a live read.
CREATE TABLE IF NOT EXISTS pool_point (
  block_number   INTEGER NOT NULL,
  log_index      INTEGER NOT NULL,
  timestamp      INTEGER,
  total_deposits TEXT NOT NULL,
  total_debt     TEXT NOT NULL,
  PRIMARY KEY (block_number, log_index)
);

-- Current position per borrower and asset, folded the same way. This is what the keeper reads
-- instead of rediscovering every borrower from the deploy block on each scan.
CREATE TABLE IF NOT EXISTS position (
  borrower     TEXT NOT NULL,
  asset        TEXT NOT NULL,
  collateral   TEXT NOT NULL,
  debt         TEXT NOT NULL,
  principal    TEXT NOT NULL,
  opened_block INTEGER NOT NULL,
  last_block   INTEGER NOT NULL,
  PRIMARY KEY (borrower, asset)
);
CREATE INDEX IF NOT EXISTS position_open ON position(debt);

CREATE TABLE IF NOT EXISTS cursor (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  last_block INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
`

export class Store {
  readonly db: DatabaseSync

  constructor(path: string) {
    this.db = new DatabaseSync(path)
    // WAL lets the API read while the sync loop writes. Both run in one process today, but the
    // two are separable and the reader must never block the writer if they are split.
    this.db.exec("PRAGMA journal_mode = WAL")
    this.db.exec("PRAGMA foreign_keys = ON")
    this.db.exec(SCHEMA)
  }

  close() {
    this.db.close()
  }

  // ------------------------------------------------------------------------------------------
  // cursor
  // ------------------------------------------------------------------------------------------

  /// The last block whose logs are fully written. Absent before the first pass.
  lastBlock(): bigint | null {
    const row = this.db.prepare("SELECT last_block FROM cursor WHERE id = 1").get() as
      | { last_block: number }
      | undefined
    return row ? BigInt(row.last_block) : null
  }

  setLastBlock(block: bigint) {
    this.db
      .prepare(
        "INSERT INTO cursor (id, last_block, updated_at) VALUES (1, ?, ?) " +
          "ON CONFLICT(id) DO UPDATE SET last_block = excluded.last_block, updated_at = excluded.updated_at"
      )
      .run(Number(block), Math.floor(Date.now() / 1000))
  }

  cursorUpdatedAt(): number | null {
    const row = this.db.prepare("SELECT updated_at FROM cursor WHERE id = 1").get() as
      | { updated_at: number }
      | undefined
    return row?.updated_at ?? null
  }

  // ------------------------------------------------------------------------------------------
  // writes
  // ------------------------------------------------------------------------------------------

  /// Writes a batch of events and their derived consequences as one transaction. Either the
  /// whole range lands and the cursor moves with it, or nothing does: a crash mid-write must not
  /// leave a cursor claiming blocks whose events were never stored.
  writeBatch(events: EventRow[], prices: PricePoint[], upTo: bigint) {
    const insertEvent = this.db.prepare(
      "INSERT OR REPLACE INTO event " +
        "(block_number, log_index, tx_hash, timestamp, source, address, name, actor, asset, args) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    const insertPrice = this.db.prepare(
      "INSERT OR REPLACE INTO price (feed, block_number, log_index, updated_at, answer) VALUES (?, ?, ?, ?, ?)"
    )
    this.db.exec("BEGIN")
    try {
      for (const row of events) {
        insertEvent.run(
          Number(row.blockNumber),
          row.logIndex,
          row.txHash,
          row.timestamp,
          row.source,
          row.address,
          row.name,
          row.actor,
          row.asset,
          JSON.stringify(row.args)
        )
      }
      for (const point of prices) {
        insertPrice.run(point.feed, Number(point.blockNumber), point.logIndex, point.updatedAt, point.answer)
      }
      this.setLastBlock(upTo)
      this.db.exec("COMMIT")
    } catch (error) {
      this.db.exec("ROLLBACK")
      throw error
    }
  }

  /// Drops everything at or above a block, for a reorg. The derived tables go with it and are
  /// refolded, because a fold cannot be undone one step at a time without keeping every step.
  rewindTo(block: bigint) {
    this.db.exec("BEGIN")
    try {
      this.db.prepare("DELETE FROM event WHERE block_number >= ?").run(Number(block))
      this.db.prepare("DELETE FROM price WHERE block_number >= ?").run(Number(block))
      this.db.exec("DELETE FROM pool_point")
      this.db.exec("DELETE FROM position")
      this.setLastBlock(block - 1n)
      this.db.exec("COMMIT")
    } catch (error) {
      this.db.exec("ROLLBACK")
      throw error
    }
  }

  setFeedMeta(feed: string, decimals: number, description: string | null) {
    this.db
      .prepare("INSERT OR REPLACE INTO feed_meta (feed, decimals, description) VALUES (?, ?, ?)")
      .run(feed, decimals, description)
  }

  feedMeta(feed: string): { decimals: number; description: string | null } | null {
    const row = this.db.prepare("SELECT decimals, description FROM feed_meta WHERE feed = ?").get(feed) as
      | { decimals: number; description: string | null }
      | undefined
    return row ?? null
  }

  // ------------------------------------------------------------------------------------------
  // derived state
  // ------------------------------------------------------------------------------------------

  writePoolPoint(blockNumber: bigint, logIndex: number, timestamp: number | null, deposits: bigint, debt: bigint) {
    this.db
      .prepare(
        "INSERT OR REPLACE INTO pool_point (block_number, log_index, timestamp, total_deposits, total_debt) " +
          "VALUES (?, ?, ?, ?, ?)"
      )
      .run(Number(blockNumber), logIndex, timestamp, deposits.toString(), debt.toString())
  }

  latestPoolPoint(): { deposits: bigint; debt: bigint } | null {
    const row = this.db
      .prepare("SELECT total_deposits, total_debt FROM pool_point ORDER BY block_number DESC, log_index DESC LIMIT 1")
      .get() as { total_deposits: string; total_debt: string } | undefined
    return row ? { deposits: BigInt(row.total_deposits), debt: BigInt(row.total_debt) } : null
  }

  writePosition(row: {
    borrower: string
    asset: string
    collateral: bigint
    debt: bigint
    principal: bigint
    openedBlock: bigint
    lastBlock: bigint
  }) {
    this.db
      .prepare(
        "INSERT INTO position (borrower, asset, collateral, debt, principal, opened_block, last_block) " +
          "VALUES (?, ?, ?, ?, ?, ?, ?) " +
          "ON CONFLICT(borrower, asset) DO UPDATE SET collateral = excluded.collateral, debt = excluded.debt, " +
          "principal = excluded.principal, last_block = excluded.last_block"
      )
      .run(
        row.borrower,
        row.asset,
        row.collateral.toString(),
        row.debt.toString(),
        row.principal.toString(),
        Number(row.openedBlock),
        Number(row.lastBlock)
      )
  }

  position(borrower: string, asset: string) {
    const row = this.db
      .prepare("SELECT collateral, debt, principal, opened_block, last_block FROM position WHERE borrower = ? AND asset = ?")
      .get(borrower, asset) as
      | { collateral: string; debt: string; principal: string; opened_block: number; last_block: number }
      | undefined
    if (!row) return null
    return {
      collateral: BigInt(row.collateral),
      debt: BigInt(row.debt),
      principal: BigInt(row.principal),
      openedBlock: BigInt(row.opened_block),
      lastBlock: BigInt(row.last_block)
    }
  }

  /// Every borrower and asset the pool has ever seen, most recently active first. `openOnly`
  /// narrows it to the ones that still carry debt, which is all the keeper needs to look at.
  positions(openOnly: boolean) {
    const sql =
      "SELECT borrower, asset, collateral, debt, principal, opened_block, last_block FROM position " +
      (openOnly ? "WHERE debt != '0' " : "") +
      "ORDER BY last_block DESC"
    return (
      this.db.prepare(sql).all() as {
        borrower: string
        asset: string
        collateral: string
        debt: string
        principal: string
        opened_block: number
        last_block: number
      }[]
    ).map(row => ({
      borrower: row.borrower,
      asset: row.asset,
      collateral: row.collateral,
      debt: row.debt,
      principal: row.principal,
      openedBlock: row.opened_block,
      lastBlock: row.last_block
    }))
  }

  /// Events in chain order. Used by the fold, so it must never reorder.
  allEventsInOrder(): EventRow[] {
    return this.rowsToEvents(
      this.db.prepare("SELECT * FROM event ORDER BY block_number ASC, log_index ASC").all() as RawEvent[]
    )
  }

  eventsForActor(actor: string, limit: number, before: bigint | null): EventRow[] {
    const rows = before
      ? (this.db
          .prepare(
            "SELECT * FROM event WHERE actor = ? AND block_number < ? ORDER BY block_number DESC, log_index DESC LIMIT ?"
          )
          .all(actor, Number(before), limit) as RawEvent[])
      : (this.db
          .prepare("SELECT * FROM event WHERE actor = ? ORDER BY block_number DESC, log_index DESC LIMIT ?")
          .all(actor, limit) as RawEvent[])
    return this.rowsToEvents(rows)
  }

  eventsByName(names: string[], limit: number): EventRow[] {
    const placeholders = names.map(() => "?").join(",")
    const rows = this.db
      .prepare(
        `SELECT * FROM event WHERE name IN (${placeholders}) ORDER BY block_number DESC, log_index DESC LIMIT ?`
      )
      .all(...names, limit) as RawEvent[]
    return this.rowsToEvents(rows)
  }

  poolSeries(limit: number) {
    return (
      this.db
        .prepare(
          "SELECT block_number, timestamp, total_deposits, total_debt FROM pool_point " +
            "ORDER BY block_number DESC, log_index DESC LIMIT ?"
        )
        .all(limit) as { block_number: number; timestamp: number | null; total_deposits: string; total_debt: string }[]
    ).reverse()
  }

  /// The feed answer in force at a block: the last update at or before it. This is the price the
  /// pool would have read, recovered from logs because the state is long gone.
  priceAt(feed: string, blockNumber: bigint): PricePoint | null {
    const row = this.db
      .prepare(
        "SELECT feed, block_number, log_index, updated_at, answer FROM price " +
          "WHERE feed = ? AND block_number <= ? ORDER BY block_number DESC, log_index DESC LIMIT 1"
      )
      .get(feed, Number(blockNumber)) as
      | { feed: string; block_number: number; log_index: number; updated_at: number; answer: string }
      | undefined
    if (!row) return null
    return {
      feed: row.feed,
      blockNumber: BigInt(row.block_number),
      logIndex: row.log_index,
      updatedAt: row.updated_at,
      answer: row.answer
    }
  }

  /// Which feed an asset was on at a block, from the PriceFeedSet history. An asset can be
  /// repointed, and a liquidation must be priced against the feed in force at the time.
  feedForAssetAt(asset: string, blockNumber: bigint): string | null {
    const row = this.db
      .prepare(
        "SELECT args FROM event WHERE name = 'PriceFeedSet' AND asset = ? AND block_number <= ? " +
          "ORDER BY block_number DESC, log_index DESC LIMIT 1"
      )
      .get(asset, Number(blockNumber)) as { args: string } | undefined
    if (!row) return null
    const feed = (JSON.parse(row.args) as Record<string, string>).feed
    return feed && !/^0x0+$/.test(feed) ? feed : null
  }

  /// The manual price in force at a block, for an asset with no feed.
  manualPriceAt(asset: string, blockNumber: bigint): string | null {
    const row = this.db
      .prepare(
        "SELECT args FROM event WHERE name = 'PriceSet' AND asset = ? AND block_number <= ? " +
          "ORDER BY block_number DESC, log_index DESC LIMIT 1"
      )
      .get(asset, Number(blockNumber)) as { args: string } | undefined
    if (!row) return null
    return (JSON.parse(row.args) as Record<string, string>).priceUsd1e18 ?? null
  }

  counts() {
    const events = (this.db.prepare("SELECT COUNT(*) AS n FROM event").get() as { n: number }).n
    const prices = (this.db.prepare("SELECT COUNT(*) AS n FROM price").get() as { n: number }).n
    const positions = (this.db.prepare("SELECT COUNT(*) AS n FROM position").get() as { n: number }).n
    const open = (this.db.prepare("SELECT COUNT(*) AS n FROM position WHERE debt != '0'").get() as { n: number }).n
    return { events, prices, positions, openPositions: open }
  }

  private rowsToEvents(rows: RawEvent[]): EventRow[] {
    return rows.map(row => ({
      blockNumber: BigInt(row.block_number),
      logIndex: row.log_index,
      txHash: row.tx_hash,
      timestamp: row.timestamp,
      source: row.source,
      address: row.address,
      name: row.name,
      actor: row.actor,
      asset: row.asset,
      args: JSON.parse(row.args) as Record<string, string>
    }))
  }
}

type RawEvent = {
  block_number: number
  log_index: number
  tx_hash: string
  timestamp: number | null
  source: string
  address: string
  name: string
  actor: string | null
  asset: string | null
  args: string
}
