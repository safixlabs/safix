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
