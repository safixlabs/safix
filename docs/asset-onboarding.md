# Onboarding an asset

A checklist, not a decision. The decisions are in [risk-parameters.md](risk-parameters.md); this is what you do once they are made.

Each step blocks the next. An asset that fails a step does not get onboarded with a note to come back to it.

---

## 0. Before anything

Place the asset in a class from [risk-parameters.md](risk-parameters.md) and write down why. The class fixes the LTV, the liquidation threshold, the deviation limit and the band. If you find yourself arguing for an exception, the answer is a different class, not a different number.

## 1. Verify the token

```
cast call $TOKEN 'name()(string)'        --rpc-url $RPC
cast call $TOKEN 'symbol()(string)'      --rpc-url $RPC
cast call $TOKEN 'decimals()(uint8)'     --rpc-url $RPC
cast call $TOKEN 'uiMultiplier()(uint256)' --rpc-url $RPC
```

- **Decimals must be 18.** The pool's valuation divides by `1e30`, which assumes an 18-decimal collateral against a 6-decimal stable. A token with different decimals is not a configuration change, it is a code change.
- **`uiMultiplier` must answer.** This is the ERC-8056 interface every Robinhood stock token exposes, and it is the cleanest way to tell a real one from a token that copied the name. On Robinhood Chain testnet, `uiMultiplier` reverts on lookalikes and answers on the genuine article.
- **Record the multiplier.** Write it into the deployment note. It is `1e18` for an asset that has had no corporate action, and it changing is how you learn one happened.

Verify the address against the official registry. A token that matches on symbol but not on address is the attack, not a coincidence: the testnet explorer lists several tokens called "Amazon".

## 2. Find and verify the feed

Chainlink's directory publishes mainnet feeds at `reference-data-directory.vercel.app/feeds-robinhood-mainnet.json`. **Testnet feeds are not published there.** They exist on chain and can be found through any protocol already consuming them — an Aave-style price oracle exposes `getSourceOfAsset(token)`, which returns the feed address directly.

```
cast call $FEED 'description()(string)'  --rpc-url $RPC   # must name the pair
cast call $FEED 'decimals()(uint8)'      --rpc-url $RPC   # must be <= 18
cast call $FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $RPC
```

- **`description` must name the asset you think it does.** Reading a feed for the wrong ticker is silent and total.
- **`decimals` must be 18 or fewer.** `setPriceFeed` enforces this, but find out here rather than at the transaction.
- **`answer` must be positive and `updatedAt` non-zero.** A feed that has never reported is not a feed.
- **Record the heartbeat.** It becomes `maxPriceAge`.

## 3. Check the price against something else

The feed is one source. Before the pool acts on it, confirm it agrees with an independent one within tolerance.

The cleanest independent source for a testnet feed is **the mainnet feed for the same asset**: a different contract, on a different chain, maintained separately.

```
# testnet
cast call $TESTNET_FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $TESTNET_RPC
# mainnet
cast call $MAINNET_FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $MAINNET_RPC
```

Within **10%** is a pass on testnet, where the feed may be days or months behind. On mainnet the tolerance is **2%**, and a wider gap stops the onboarding until it is explained.

Record both numbers and the date. A gap that is fine today because the feed is old is not fine tomorrow for the same reason.

## 4. Corporate actions

**The feed reports the token's Total Return Value**, which is the underlying equity's price combined with the multiplier read from the token contract itself. A split changes the feed's answer; the holder's balance does not change; the pool's valuation stays correct without doing anything.

**The pool must never apply `uiMultiplier` itself.** Doing so would scale the value twice, and the error is invisible while the multiplier is `1.0` — which is exactly when it would be introduced. `SafixPool` does not read `uiMultiplier` anywhere, and that is deliberate.

Confirm before onboarding:

```
# what the pool says a holding is worth
cast call $POOL 'collateralValueStable(address,uint256)(uint256)' $TOKEN 1000000000000000000 --rpc-url $RPC
# what the feed says one unit costs
cast call $FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $RPC
```

They must agree to the token's decimals, with **no multiplier applied on top**. If the pool's number is the feed's number times the multiplier, something has been double-counted.

After any corporate action, re-record `uiMultiplier` and repeat step 3. A split is the moment a stale price check earns its place.

## 5. Configure

Four transactions, in this order. **After the timelock is wired they all go through it**, so queue them together and execute them together, or the asset is onboarded a piece at a time over four separate delays.

```
configureAsset(token, maxLtvBps, liqThresholdBps, 0)   # price 0: the feed is the source
setPriceFeed(token, feed)
setPriceGuard(token, maxPriceAge, maxDeviationBps, minPrice, maxPrice)
setAssetCaps(token, debtCap, collateralCap)
```

- `configureAsset` last argument is **zero**. The manual price is a fallback for assets with no feed; setting one here leaves a stale number behind the feed.
- `maxPriceAge` is the feed's heartbeat **on mainnet**. On testnet it is whatever the feed's actual cadence is, which may be nothing at all — see the note below.
- Band and deviation come from the asset's class.
- Caps come from the lower of the pool-side and volume-side calculations in [risk-parameters.md](risk-parameters.md).

**An asset is never enabled and left uncapped.** `configureAsset` alone leaves `debtCap` at zero, which means uncapped, which is the opposite of what a half-finished onboarding should mean. If you cannot complete step 5, do not start it.

## 6. Verify on chain

```
cast call $POOL 'priceStatus(address)(uint8,uint256,uint256)' $TOKEN --rpc-url $RPC
```

`0` is `Ok`. Anything else and the pool will not act on the price, which means the asset is configured but not usable. The reasons are listed in `contracts/README.md`.

Then confirm the price the pool reports equals the feed's answer scaled to 18 decimals, and that a small draw against the asset succeeds.

## 7. Record it

Add to the deployment note: token address, feed address, feed description, decimals, heartbeat, `uiMultiplier` at onboarding, the independent price and its date, and the parameters chosen with the class they came from.

---

## Testnet feeds are not maintained

Robinhood Chain testnet has real Chainlink feeds with the right interface and real prices, but **they stop being updated**. As of onboarding, every stock feed on testnet last reported on 9 June 2026 — around 90 days stale — while the mainnet feeds for the same assets were within three days.

This matters twice:

**`maxPriceAge` on testnet cannot be the mainnet heartbeat.** Set to `86400`, the pool correctly refuses every testnet price as `Stale` and the asset is unusable. The testnet value is set to accommodate the feed's actual cadence, and this is the one parameter that is deliberately different between the two chains. **On mainnet it is the heartbeat, with no exceptions.**

**A testnet price is old, not wrong.** The 5% gap against mainnet for AMZN is ninety days of price movement, not a broken feed. Do not tune a band or a deviation limit to make a stale testnet price fit; set them from the class and accept that testnet prices sit inside a wider band than they would live.

---

## Worked example: AMZN

The first real asset, onboarded on testnet on 7 September 2026.

| Step | Value |
| --- | --- |
| Class | C, single stock |
| Token | [`0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02`](https://explorer.testnet.chain.robinhood.com/address/0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02) |
| Name, symbol, decimals | Amazon, AMZN, 18 |
| `uiMultiplier` at onboarding | `1e18` — no corporate action so far |
| Feed | [`0x57558663AF6d0212a8E152BdcB78f130aCC6486C`](https://explorer.testnet.chain.robinhood.com/address/0x57558663AF6d0212a8E152BdcB78f130aCC6486C) |
| Feed description, decimals | `AMZN / USD`, 8 |
| Feed answer | `24524826000` → $245.25, round 484 |
| Independent check | mainnet feed `0xD5a1508c…` reported $258.73 — **5.2% apart**, within the 10% testnet tolerance |
| Max LTV / threshold | 5500 / 7000 |
| Deviation limit | 2000 bps |
| Band | $24.53 – $465.97, ±90% of the onboarding price |
| `maxPriceAge` | 10,368,000s on testnet, **86,400s on mainnet** |
| Debt cap | 37,500 USDG, 15% of a 250,000 pool |
| Collateral cap | 347 AMZN, the collateral that debt needs at 55% LTV plus a quarter |

**Why AMZN first.** Of the five stock tokens on testnet it is the most liquid name and the largest capitalisation, so it is the one whose price is least likely to be an artefact of thin trading. It also had the closest agreement with its mainnet feed — 5.2% against 15.5% for TSLA and 21.6% for PLTR, which is ninety days of a more volatile name moving further.

**Verified after configuration:** `priceStatus` returned `0`, `currentPrice` returned `245248260000000000000` — exactly the feed's `24524826000` scaled by `1e10` — and `collateralValueStable` for 5 AMZN returned `1226241300`, which is 5 × $245.25 with no multiplier applied on top.

**Borrowed against, live:** 5 AMZN locked, 600 USDG drawn, debt 603 including the origination fee.

- approve [`0xb91ae2d2…`](https://explorer.testnet.chain.robinhood.com/tx/0xb91ae2d28ab1a59921aad895b557acef1f3557e6dcc50aec75c65a6eea5d6fd5)
- lock [`0x7eb94d38…`](https://explorer.testnet.chain.robinhood.com/tx/0x7eb94d38d101249df5f353cbade8fb3627ff96e9aff0e49af6cc3785c2bdd0d8)
- draw [`0xb8d7ba8e…`](https://explorer.testnet.chain.robinhood.com/tx/0xb8d7ba8ef80ede01d8822943bb8ff10453dbe710d0c77806f7caf421b4129ec4)

## The other four, when they are wanted

Found and verified the same way, not yet configured. Prices are from the testnet feeds, which are ninety days stale; the gap column is against each asset's own mainnet feed.

| Asset | Token | Feed | Testnet | Mainnet | Gap |
| --- | --- | --- | --- | --- | --- |
| AMD | `0x71178BAc…` | `0x63C4a818…` | $490.41 | $477.70 | 2.7% |
| TSLA | `0xC9f9c869…` | `0x518C0E28…` | $408.91 | $353.98 | 15.5% |
| PLTR | `0x1FBE1a0e…` | `0xB6bd93Aa…` | $136.43 | $173.95 | 21.6% |
| NFLX | `0x3b8262A6…` | `0x13449c3b…` | $82.65 | no mainnet feed listed | — |

All five expose `uiMultiplier` at `1e18` and 18 decimals. AMD is the natural second: the smallest gap after AMZN, and the same class.

NFLX has no mainnet feed in Chainlink's directory, so **step 3 cannot be completed for it** and it does not get onboarded until it can. That is the checklist working.
