# Safix keeper

Off-chain worker for the Safix pool. Two jobs per pass: push manual prices for assets without a Chainlink feed, and liquidate every position the pool reports as unhealthy. Assets with a feed configured onchain need no price pushes; the keeper's liquidation scan covers them the same way.

Positions are discovered from Drawn events, so the keeper needs no registry and no database.

## Run

```
npm install
cp config.example.json config.json
PRIVATE_KEY=0x... npm run scan
PRIVATE_KEY=0x... npm run watch
```

The key needs gas on the target chain. Price pushes additionally require it to be the pool's owner or its configured price updater; liquidations work from any funded account and earn the liquidation incentive.

Config fields: `rpcUrl`, `poolAddress`, optional `deployBlock` (start of the event scan), `intervalMs` for watch mode, and `prices` as checksummed asset address to USD price.

## Failures never cascade

Liquidation is the pool's only defence, so nothing else in a pass is allowed to cost it its scan.

The pool refuses a price that falls outside an asset's configured band or moves further than its deviation limit in one update. That is the oracle guard working, and it says nothing about the other assets, so a rejected push is logged with its reason and the loop carries on. A failure anywhere in the price phase is stepped over and the liquidation scan still runs. Within that scan, one position failing — another keeper got there first, or it stopped being liquidatable between the read and the send — does not stop the rest.

`isLiquidatable` answers false rather than reverting whenever the pool will not act on a price: sequencer down or inside its grace window, stale, out of band, or a single-round jump. One unusable feed skips its own positions and no others, and the keeper is never told to seize collateral on a price nobody could have reacted to.
