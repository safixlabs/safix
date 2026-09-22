# Safix keeper

Liquidation is the pool's only defence, so the keeper is production infrastructure rather than a script somebody runs. It does two things each pass: pushes manual prices for assets with no Chainlink feed, and liquidates every position the pool reports as unhealthy.

Positions are discovered from `Drawn` events, so it needs no registry and no database.

**Anyone can run one.** The incentive is real and is described at the bottom.

## Run

```
npm install
cp config.example.json config.json      # edit poolAddress and deployBlock

PRIVATE_KEY=0x... npm run scan          # one pass
PRIVATE_KEY=0x... npm run watch         # the loop
PRIVATE_KEY=0x... npm run drill         # fire one of every alert
npm test                                # config validation and gas arithmetic
```

`node scripts/wire-env.mjs testnet` from the repository root writes `config.json` from the recorded deployment, so the address and the start block are never typed by hand.

## Deploying it somewhere

The keeper is a long-lived worker: it holds a loop, a key, and a little state about which positions have been stuck. It listens on no port. Any host that restarts a container on exit will do.

A `Dockerfile` and a `fly.toml` are here because that is the shortest path from this repository to a keeper that stays up:

```
fly launch --no-deploy
fly secrets set PRIVATE_KEY=0x... ALERT_WEBHOOK_URL=https://...
fly deploy
```

`restart.policy = "always"`, and the keeper **exits non-zero on an unhandled error precisely so that fires**. A process that wedges silently is worse than one that dies loudly: the host can restart the second one.

Logs are JSON lines by default, one object per event, for whatever collects them on the host. `LOG_FORMAT=text` gives the human-readable form when running locally.

## Keys and secrets

**`PRIVATE_KEY` is read from the environment only, never from `config.json`.** The config file can be committed, logged or pasted into an issue without carrying a key with it. `ALERT_WEBHOOK_URL` is treated the same way. Both belong in the host's secret store.

**Use a dedicated key.** The keeper key needs nothing but gas: liquidating is permissionless and earns the incentive from the collateral it seizes. It should not be the deployer, the guardian, or a multisig signer. If it leaks, the worst an attacker can do is liquidate positions that were already liquidatable, which is what the keeper is for.

**Gas budget.** A liquidation costs about **150,000 gas**; measured runs on Robinhood Chain testnet land at 152,431. At the observed 0.01 to 0.02 gwei that is roughly **0.0000015 to 0.000003 ETH each**, so:

| Balance | Liquidations it covers, at 0.02 gwei |
| --- | --- |
| 0.002 ETH | ~660 |
| 0.01 ETH | ~3,300 |
| 0.05 ETH | ~16,600 |

The keeper reports its balance as **the number of liquidations it can still afford**, because that is the unit an on-call engineer can act on. "0.004 ETH" means nothing at 3am; "12 liquidations left" does.

Alert thresholds are set in the same unit: `gas.warnLiquidations` and `gas.criticalLiquidations`. The gap between them is the time somebody has to top the key up. The config refuses to load if critical is not below warn, since the warning would never fire first.

## Alerts

Four things are worth waking someone for, and nothing else. An alert that fires on something nobody acts on trains people to ignore the channel, which costs more than the alert saved.

| Alert | Severity | Fires when |
| --- | --- | --- |
| `scan_failed` | warning, critical after 3 in a row | a whole pass failed: the RPC is unreachable, or something threw where nothing should |
| `tx_reverted` | warning | a liquidation reverted for a reason that is not another keeper getting there first |
| `position_stuck` | critical | a position has stayed liquidatable across `alerts.stuckScans` consecutive passes |
| `gas_low` | warning, then critical | the key is running out of gas, with enough warning to top it up |

Delivery is a webhook, in a shape both Slack and Discord accept, so the channel is configuration rather than a code change. The same alert stays quiet for `alerts.cooldownMs` after firing, deduplicated on kind plus subject, so an ongoing incident does not become a flood — a stuck position on one asset does not silence one on another.

**Delivery failures are logged and swallowed.** A keeper that dies because its alerting is down is strictly worse than one that keeps liquidating quietly.

`npm run drill` fires one of every alert so the channel, the routing and the on-call rotation can be tested without waiting for a real incident.

## Finding positions

The keeper has to know which borrower and asset pairs exist before it can ask whether any of them
are liquidatable. There are two ways, and it prefers the cheap one without depending on it.

**From the index**, when `indexer.url` (or `INDEXER_URL`) is set: one request for the open
positions. The keeper checks `/status` first and refuses an index that is more than
`indexer.maxLagBlocks` behind the head — an index that is behind still *answers*, so the fallback
would never fire, and the positions it omits are the newest ones, which are the likeliest to be
undercollateralised. Rows are validated as addresses before they reach a contract call: the index
is a service the keeper does not control.

**From the logs**, otherwise, or whenever the index does not answer in `indexer.timeoutMs`: replay
every `Drawn` event from the deploy block. This is what the keeper did before the index existed. It
is self-sufficient and correct, and it gets slower every day — Robinhood Chain produces around
689,000 blocks a day, so the scan grows without bound.

That order is deliberate in both directions. The index makes the keeper cheaper; it is never
allowed to make it fragile. **Liquidation is the one thing in the protocol that must not wait on a
service the team runs.** There are tests for both paths, and the fallback is exercised by pointing
the keeper at a port with nothing on it.

## Running more than one

Safe, and worth doing: two keepers in different regions survive one host going down.

Liquidating is **idempotent by construction**. The pool answers `isLiquidatable` false the moment anybody clears a position, and refuses the call outright if it is already healthy. Two keepers racing therefore cost one wasted transaction, never a double liquidation. Reverts that mean *somebody got there first* — `healthy`, `liquidations paused`, `zero` — are logged and never alerted on.

Positions are attempted in a **shuffled order**, so two keepers scanning the same pool at the same moment mostly work on different ones rather than racing on the same position every pass.

**Give each instance its own key.** Two processes sharing one key will collide on nonces. Set `INSTANCE_ID` per instance so logs and alerts say which one is speaking.

## What it will not do

Liquidations are skipped, not forced, when the pool says the price cannot be trusted: sequencer down or inside its grace window, stale, outside the asset's band, or a single-round jump. `isLiquidatable` returns false in all of those, so **the keeper is never told to seize collateral on a price nobody could have reacted to**. It also stops when the guardian has paused liquidations, and says so in the log rather than retrying into a revert.

A price the pool refuses — outside the asset's band, or moving further than its deviation limit in one update — is logged and stepped over. That is the oracle guard working, and it says nothing about the other assets, so the rest of the pass continues. **A failure anywhere in the price phase never costs the liquidation scan its turn.**

## The incentive, for anyone considering running one

`liquidationIncentiveBps` of the collateral seized goes to whoever sent the transaction, currently **0.5%**. On a 5,000 USDG position that is about 25 USDG of collateral for roughly 0.000003 ETH of gas.

It is permissionless. Liquidating needs no allowlist, no passport and no relationship with the protocol — only a funded key. The pool is better off with several independent keepers than with one, so competition here is the design rather than a tolerated side effect.

Config fields: `rpcUrl`, `poolAddress`, optional `deployBlock` (start of the event scan), `intervalMs`, `logChunkBlocks` (largest span per `getLogs`, for RPCs that cap it), `instanceId`, `prices` as checksummed asset address to USD price, plus the `alerts`, `gas` and `indexer` blocks described above.

## Running it without a host

`.github/workflows/keeper.yml` runs one pass every fifteen minutes. It does the
same work a hosted keeper does, and needs nothing deployed: prices that are ageing
get written, positions that have fallen through their threshold get liquidated.

Two secrets on the repository:

| Secret | What it is |
| --- | --- |
| `KEEPER_PRIVATE_KEY` | The key the pool accepts for `setPrice`, which is either the owner or the address in `priceUpdater()`. It also pays for liquidations, so it needs gas. |
| `ALERT_WEBHOOK_URL` | Optional. Without it the alerts only reach the run's log, where nobody is looking. |

Three things to know before relying on it.

**It is for the testnet and nothing else.** That key can post prices and liquidate
on the pool it is pointed at. A key with any authority over real money does not
belong in a CI secret, whatever the convenience.

**A cron is not a promise.** GitHub runs a schedule when it has capacity, and
delays of several minutes are ordinary. The margin is why the pass runs four times
inside the tightest window rather than once.

**It stops on its own.** GitHub disables a scheduled workflow after sixty days
without a push, and says so only by email. A quiet repository stops keeping the
pool alive without anything appearing to fail.

A hosted keeper has none of those three caveats, which is why `fly.toml` is still
here and this is the way to keep a testnet open until it runs.
