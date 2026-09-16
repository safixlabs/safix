# Safix indexer

Reads the protocol's events into a SQLite file and serves them over HTTP. It holds no key, signs
nothing, and everything it stores is already public in the chain's logs.

**It is an enhancement, never a dependency.** The keeper falls back to scanning logs when it cannot
be reached, the app falls back to reading the chain, and both paths have tests.

```
npm install
cp config.example.json config.json      # edit poolAddress and deployBlock

npm run sync         # one pass, then exit
npm run watch        # the loop, with the read API alongside it
npm run serve        # the API alone, against whatever the file already holds
npm run status       # what the index knows
npm run reconcile    # fold against chain; exits non-zero on any disagreement
npm test
```

---

## What Robinhood Chain supports

Every number here was measured against `rpc.testnet.chain.robinhood.com`, because the stack choice
turns on them and none of them are in the chain's documentation.

| Property | Measured | Why it matters |
| --- | --- | --- |
| Block time | **0.1254 s** → ~689,000 blocks/day, ~251M/year | Anything that costs one request per block is unaffordable |
| `eth_getLogs` limit | **10,000 matched logs**, no block-range cap | Chunk on log count, not on blocks |
| JSON-RPC batch limit | **exactly 100** (101 returns `429`) | Sets the timestamp batch size |
| State retention | **~6,268 blocks ≈ 13 minutes** | `eth_call` at a historical block is not available |
| `finalized` lag | ~9,500 blocks ≈ 20 min | Sets the reorg window |
| Single-call latency | ~275 ms | Batching is worth more than concurrency |
| `eth_newFilter`, `debug_*`, `trace_*` | **not available** | No subscription or trace-based indexing |

Two of those decide almost everything.

**State is kept for thirteen minutes.** A call to `totalDeposits()` at last Tuesday's block does not
return a stale answer — it returns `missing trie node`. So the pool's history cannot be sampled; it
has to be *derived from events*, which is what [`src/fold.ts`](src/fold.ts) does, and which
`reconcile` then checks against a live read.

**The chain produces eight blocks a second.** Any indexer whose work is proportional to blocks is
paying 689,000 times a day to watch three contracts that have emitted a few dozen logs.

## The stack decision

The issue asked for a subgraph, Ponder, or a small indexer, decided on what the chain supports. All
three were checked rather than reasoned about.

### A subgraph cannot be deployed here

The Graph's own networks registry lists Robinhood Chain — and lists no subgraph service for it:

```
$ curl -s https://networks-registry.thegraph.com/TheGraphNetworksRegistry.json | jq '.networks[] | select(.caip2Id=="eip155:46630")'
{
  "id": "robinhood-sepolia",
  "caip2Id": "eip155:46630",
  "services": { "subgraphs": [], "substreams": [...], "firehose": [...] },
  "issuanceRewards": false,
  ...
}
```

`services.subgraphs` is empty. 65 of the registry's 159 networks carry
`https://api.studio.thegraph.com/deploy`; this is one of the 94 that do not, and `issuanceRewards`
is `false`, so no indexer on the decentralised network would pick it up either. Firehose and
Substreams endpoints do exist (Pinax, StreamingFast), so self-hosting a graph-node is *possible* —
at the cost of graph-node, IPFS, Postgres and a third-party stream, to answer the same questions.

### Ponder cannot keep up with the chain

Ponder 0.17.9 was installed and pointed at the pool. Its historical backfill was **fine**: 7
seconds, correct, no complaints.

Its realtime stage is the problem. From `ponder/src/sync-realtime/index.ts`:

```js
const MAX_QUEUED_BLOCKS = 50;
...
const pendingBlocks = await Promise.all(
  missingBlockRange.map((blockNumber) =>
    eth_getBlockByNumber(args.rpc, [numberToHex(blockNumber), true], ...)
```

It walks **every block**, one request each, with full transaction bodies, because that is how it
detects reorgs. On this chain that is 689,000 full-block fetches a day, and it can advance at most
50 blocks per cycle against a chain producing 8 per second.

Observed over 90 seconds: **43 distinct blocks fetched, 77 timeouts, one 429**, while the chain
produced roughly 720 blocks. It falls behind at eight times the rate it catches up, so it never
converges. `pollingInterval` does not help — it makes the gap larger. A paid RPC would raise the
ceiling but not change the arithmetic.

This is not a criticism of Ponder. It is a good tool whose reorg model assumes blocks are a scarce
resource, and on this chain they are not.

### So: a small indexer

The work here is proportional to **events**, not blocks:

- one `eth_getLogs` per pass, over the whole outstanding range
- block timestamps only for the blocks that actually carry an event, batched at 100

A full sync of the current deployment — 119,000 blocks, three contracts and a price feed with 483
rounds — takes **2.7 seconds and 2 `eth_getLogs` calls**. Ponder needed 43 requests to move 43
blocks.

It also matches what already runs here: the keeper and the monitor are viem and `node:test` with no
framework, and this is a third worker of the same shape.

## Storage

SQLite, from Node's own standard library (`node:sqlite`) — no driver, no server, no migration tool.
The index holds the protocol's events, which number in the thousands; a single file that can be
copied, opened with the `sqlite3` binary and deleted to force a resync is worth more than anything
that has to be running before the indexer can start.

| Table | Holds |
| --- | --- |
| `event` | Every indexed log, keyed by `(block_number, log_index)`, arguments as JSON with bigints as strings |
| `price` | `AnswerUpdated` from every feed the pool has been pointed at |
| `feed_meta` | A feed's decimals and description, read once |
| `pool_point` | Pool size and debt after each event that moved either, **folded from events** |
| `position` | Current collateral, debt and outstanding principal per borrower and asset, folded the same way |
| `cursor` | The last fully-written block |

`pool_point` and `position` are derived, so a reorg deletes and refolds them. Events and prices are
not: they are the only durable copy of anything, and are written before the fold in the same
transaction as the cursor.

## Liquidation prices

`Liquidated` carries the debt cleared and the collateral seized. It does not carry a price, and
`collateralSeized` is a pro-rata share of the position rather than a priced amount, so the price
cannot be backed out of the event.

It also cannot be read back: the state that priced it is gone thirteen minutes later.

**The feed's own logs are the answer.** Logs are not pruned. Chainlink aggregators emit
`AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt)` on every round,
so the price in force at any block is the last such log at or before it. The AMZN feed on testnet
has 483 of them going back to block 235,807.

`feedForAssetAt` picks the feed the pool was reading **at that block**, from the `PriceFeedSet`
history, because an asset can be repointed and pricing an old liquidation against today's feed
would be silently wrong.

When nothing covers the block, the price is `null` and the row says so. It is never guessed.

> On this testnet, `getRoundData(id)` returns the same answer for every `id` — the deployed feed
> ignores the argument. The event log is per-round and correct, which is a second reason to read
> history from logs rather than from calls.

## The API

Read-only, no key, CORS open — every row is already public in the chain's logs.

| Route | Answers |
| --- | --- |
| `GET /health` | Whether the process is up. Deliberately trivial; a restart policy should not kill an index that is merely behind |
| `GET /status` | Cursor, head, blocks behind, row counts, last error |
| `GET /positions?open=true` | Every borrower and asset pair. **This is what the keeper reads** |
| `GET /history/:address?limit=&before=` | A wallet's own history across all three contracts, newest first |
| `GET /position/:borrower/:asset` | One position, folded, with the events that produced it |
| `GET /pool/history?limit=` | Pool size, debt and utilisation over time |
| `GET /liquidations?limit=` | Liquidations with the price the pool acted on |
| `GET /partnerships?id=` | The partnership lifecycle |
| `GET /attestations/:address` | What a wallet's passport has had attested and withdrawn |
| `GET /prices/:feed` | A feed's price timeline |

### A note on the passport

The registry's events are indexed because the issue asks for attestation history and because a
subject should be able to read back what was attested about them and when.

**The API never lists subjects.** `/attestations/:address` answers only for an address the caller
already names — the same question the chain already answers, made fast. There is no route that
enumerates attested wallets, and there should not be: a list of them is exactly the profile
`docs/passport-policy.md` says not to build. Nothing stored here is a fact about a person; it is a
bitmask and a date, both already public.

## Reconciliation

The pool's history is derived, so the derivation has to be checked: — here against a local deployment carrying a partially repaid position, the case where principal and debt part company:

```
$ npm run reconcile
INFO reconcile.match field=totalDeposits indexed=249945200001 chain=249945200001 difference=0
INFO reconcile.match field=totalDebt indexed=1310000000 chain=1310000000 difference=0
INFO reconcile.match field=0x90f7…/0xe7f1… collateral indexed=50000000000000000000 chain=50000000000000000000 difference=0
INFO reconcile.match field=0x90f7…/0xe7f1… debt indexed=1310000000 chain=1310000000 difference=0
INFO reconcile.match field=0x90f7…/0xe7f1… principal indexed=1303482588 chain=1303482588 difference=0
INFO reconcile.done block=72 positions=3 mismatches=0
```

It rebuilds from stored events rather than trusting the running fold, so it checks two things at
once: that the fold matches the contract, and that folding all at once matches folding in pieces as
events arrived. **Exits non-zero on any disagreement**, so it is usable in CI or a cron rather than
only by eye.

Each rule in `src/fold.ts` names the line in `SafixPool` it mirrors. The one that is not obvious:
`PositionClosed` does not carry the debt it cleared, so the fold supplies it from the running
position — the only pool quantity no single log can answer for. And a repayment retires principal
in proportion to the debt it repays, rounded down exactly as the pool rounds it, so the fold's
principal stays at or below its debt the way the contract's does; the redemption fee the repayment
paid is on record in `RedemptionFeePaid` and never moves the debt.

## Reorgs

Everything within `reorgDepthBlocks` (default 12,000, about 25 minutes, comfortably past the node's
~20 minute `finalized` lag) is re-read every pass. Rows are keyed by block and log index, so a
re-read that finds the same logs is a no-op and one that finds different logs replaces them. The
derived tables are dropped and refolded, because a fold cannot be stepped backwards without keeping
every step.

## Deploying it

Same shape as the keeper and the monitor: a long-lived worker, restarted on exit, holding one
SQLite file. It needs a volume — losing the file costs a resync, not data, but a resync on every
restart is waste.

It has no secret to hold. There is a test that pins that.

Config: `rpcUrl`, `poolAddress`, `deskAddress`, `registryAddress`, `deployBlock`, `intervalMs`,
`databasePath`, `port`, `logChunkBlocks`, `reorgDepthBlocks`, `timestampBatchSize`, `instanceId`.
