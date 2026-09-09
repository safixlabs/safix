# Safix monitor

Watches the protocol and says when something is wrong. It reads the chain and sends alerts, and that is all it can do.

**It holds no key.** There is nowhere in the configuration for one, and there is a test that pins that. The thing watching the protocol should not be able to move it: a fully compromised monitor costs an incident report and no funds.

## Run

```
npm install
cp config.example.json config.json      # edit poolAddress and deployBlock

npm run scan                            # one pass, prints every metric
npm run watch                           # the loop
npm run drill                           # fire one of every alert
npm test                                # config validation and formatting
```

`ALERT_WEBHOOK_URL` comes from the environment, never the config file. Without it, alerts still reach the log.

## The dashboard

`dashboard.html` opens in a browser and reads the pool over JSON-RPC. **No server, no build step, no database.** Every number on it is one `eth_call`, so it cannot drift from the chain the way a cached copy would, and there is nothing to keep running between incidents.

```
open dashboard.html
# or, prefilled:
open "dashboard.html?rpc=https://rpc.testnet.chain.robinhood.com&pool=0x…"
```

It is deliberately dependency-free — no framework, no library, not even for ABI encoding. Function selectors are written out with the signature each came from beside it, so the page works from `file://`, from a laptop during an incident, and from any static host. The one thing that cannot go wrong during an incident is the tool you use to look at the incident.

It shows pool size, total debt and utilisation, available and drawable liquidity, the reserve, bad debt absorbed, uncollected fees, what is paused; then per asset the price, oracle age against that asset's own limit, price status, debt and cap; then every open position sorted by how close it is to liquidation.

## Metrics

Everything comes from a contract call. There is no derived state the monitor keeps for itself, so restarting it loses nothing about the protocol.

| Metric | Source |
| --- | --- |
| Pool size, total debt, utilisation | `totalDeposits`, `totalDebt` |
| Available and drawable liquidity | `availableLiquidity`, `drawableLiquidity` |
| Protocol fees, reserve, bad debt | `protocolFees`, `reserve`, `badDebt` |
| Paused actions | `pausedActions` |
| Price, oracle age, price status per asset | `priceStatus`, `priceGuards` |
| Debt and collateral per asset, against caps | `assetDebt`, `assetCollateral`, `assetConfig` |
| Positions and how close each is to liquidation | `positions`, `isLiquidatable` |

Health is the ratio of a position's collateral value to the value at which it becomes liquidatable. Below 1.0 it already is.

## Alerts

Each one has an action. An alert with no action is noise that teaches people to ignore the channel, which costs more than the alert saved.

| Alert | Severity | Fires when | What to do |
| --- | --- | --- | --- |
| `utilisation_high` | warning, critical above 95% | the pool is lent out past its threshold | Check that liquidity is still enough for providers to exit. Consider lowering a debt cap through the timelock; it takes 48 hours, so start early. |
| `position_at_risk` | warning | a position has been liquidatable for more than `positionAtRiskSeconds` | Usually nothing: this is what the keeper is for. Check the keeper is alive and has gas. |
| `keeper_silent` | critical | a position has been liquidatable for more than `keeperSilentSeconds` | The problem is not the position. Check the keeper is running, has gas, and is not blocked by a paused pool or an unusable price. Liquidate manually if it stays. |
| `stale_price` | warning, then critical | a price is near, or past, the age the pool will act on | Warning: look at the feed. Critical: the pool has already stopped acting on it, so draws and liquidations against that asset are blocked. |
| `large_flow` | warning | a single deposit or withdrawal above `largeFlowBps` of the pool | Usually nothing, but worth knowing before someone asks. A large withdrawal moves utilisation without anybody borrowing. |
| `scan_failed` | warning, critical after 3 | the monitor could not complete a pass | The RPC, most likely. If it persists, nothing is watching the protocol, which is its own emergency. |

`position_at_risk` and `keeper_silent` are the same observation at two ages, and the config refuses to load if the second is not later than the first — otherwise they arrive together and the second says nothing new.

`stale_price` fires **before** the pool refuses the price, at `oracleAgeWarningRatio` of the asset's own limit. Once the pool refuses it, draws and liquidations are already blocked; the useful moment is while there is still time to look.

Alerts are deduplicated on kind plus subject with a cooldown, so an incident does not become a flood and a stale price on one asset does not silence one on another. Delivery failures are logged and swallowed: a monitor that dies because its alerting is down is worse than one that keeps watching quietly.

## What the keeper alerts on instead

The keeper already scans every position every fifteen seconds, so two things live there rather than here: **its own gas balance**, and **a liquidation transaction reverting**. Rebuilding that loop in the monitor would mean two systems doing the same scan and disagreeing at the edges.

The monitor repeats the keeper's gas balance in its metrics — a keeper that is down cannot tell anyone it is down — and `keeper_silent` catches the case the keeper cannot report at all: that it has stopped.

## On-call

Three of us, one week each, handing over on **Monday at 10:00 Istanbul time**.

| Week | Primary | Secondary |
| --- | --- | --- |
| 1 | A | B |
| 2 | B | C |
| 3 | C | A |

The secondary is not on call. They are who the primary calls when they need a second pair of eyes, and who takes over if the primary does not acknowledge.

**Acknowledge, then act.** Say in the channel that you have it before you start looking, so nobody else starts in parallel and nobody assumes it is handled when it is not.

### Escalation

| Time from alert | If a **critical** alert is unacknowledged |
| --- | --- |
| 0 min | Alert lands in the channel, primary is paged |
| 10 min | Secondary is paged |
| 20 min | Both remaining people are paged, by phone |

A `warning` has no clock. It is looked at during the day, and it is closed by either fixing it or explaining in the channel why it does not need fixing.

### The first thing to do, whatever the alert

Open the dashboard. It reads live chain state, needs nothing running, and shows in one screen whether this is one position, one asset, or the whole pool.

### When to pull the brake

The guardian pause is one transaction and needs no second signature. Pull it when the protocol is **taking on new risk that should not be taken**:

- a price is wrong rather than merely stale, and draws are still being accepted against it
- a collateral token behaves unexpectedly: a transfer that does not move balances, a supply that changes without a mint
- liquidations are failing for a reason nobody understands

Pausing costs a few hours of draws. Not pausing when you should costs the pool. **Being wrong about pausing is recoverable; being slow is not.** `pool.pause(PAUSE_ALL)` stops everything at once, and the exits stay open — nobody is trapped by a pause.

Unpausing needs the multisig, and it needs the incident log entry closed first: what was found, and what changed.

### Incident log

Every pause gets an entry within the hour: the pause transaction hash, the mask, what was observed, and who is handling it. The entry is updated as the picture changes; the initial one is never rewritten. The chain records that the brake was pulled and by whom — the reason belongs in the log, because an incident is a paragraph rather than a bitmask. See `contracts/README.md` for the full procedure.

## Deploying it

Same shape as the keeper: a long-lived worker that listens on nothing. Any host that restarts a container on exit will do, and the monitor exits non-zero on an unhandled error precisely so that fires.

It needs no key, so the only secret is `ALERT_WEBHOOK_URL`.

Config fields: `rpcUrl`, `poolAddress`, `deployBlock`, `intervalMs`, `logChunkBlocks`, `instanceId`, optional `keeperAddress`, plus the `alerts` and `thresholds` blocks described above.
