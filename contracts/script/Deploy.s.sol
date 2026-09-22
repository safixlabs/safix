// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {SafixTimelock} from "../src/SafixTimelock.sol";
import {PartnershipDesk} from "../src/PartnershipDesk.sol";
import {PassportRegistry} from "../src/PassportRegistry.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        // This script deploys a chain's worth of test assets: a settlement token it
        // mints itself, three wrappers standing in for collateral, prices typed in
        // here, and a pool seeded from thin air. That is what a testnet needs and
        // exactly what mainnet must never see, where settlement is USDG and the
        // collateral is the chain's own tokenized equities with their own feeds.
        //
        // Nothing here distinguishes the two, so rather than let a mainnet run make
        // a protocol out of test tokens, it stops. The mainnet path is safixlabs/safix#13
        // and the assets it lends against are safixlabs/safix#40.
        require(block.chainid != 4663, "this script deploys test assets; mainnet needs its own, see #13");

        vm.startBroadcast(deployerKey);

        MockERC20 usdc = new MockERC20("Safix Test USD", "tUSDG", 6);
        MockERC20 tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        MockERC20 bnvda = new MockERC20("Tokenized Nvidia", "bNVDA", 18);
        MockERC20 tgold = new MockERC20("Tokenized gold", "tGOLD", 18);

        SafixPool pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100.42e18);
        pool.configureAsset(address(bnvda), 5500, 7000, 172.35e18);
        pool.configureAsset(address(tgold), 6500, 8000, 3392.8e18);

        // Sanity bounds per asset: age matched to what the feed's heartbeat would be, a movement
        // limit sized to how far the asset plausibly travels between two updates, and a band around
        // where it trades. These are testnet values chosen to exercise the guards; the launch set is
        // decided with the risk parameter policy.
        pool.setPriceGuard(address(tbill), 1 days, 1_000, 50e18, 150e18);
        pool.setPriceGuard(address(bnvda), 1 hours, 2_000, 10e18, 1_000e18);
        pool.setPriceGuard(address(tgold), 1 days, 1_500, 1_000e18, 10_000e18);

        // Caps sized from docs/risk-parameters.md against the 250,000 seeded below. Debt caps are
        // the class share of pool size: A 40%, C 15%, D 15%. Each collateral cap is the collateral
        // that debt needs at the asset's own max LTV and price, plus a quarter for the position
        // that sits over-collateralised. No asset is enabled and left uncapped.
        //   tBILL  100,000 / 0.80 / 100.42  = 1,244.8, +25% -> 1,556
        //   bNVDA   37,500 / 0.55 / 172.35  =   395.6, +25% ->   495
        //   tGOLD   37,500 / 0.65 / 3392.80 =    17.0, +25% ->    22
        pool.setAssetCaps(address(tbill), 100_000e6, 1_556e18);
        pool.setAssetCaps(address(bnvda), 37_500e6, 495e18);
        pool.setAssetCaps(address(tgold), 37_500e6, 22e18);

        // Global ceiling 50% of pool size, minimum position 500 stable, liquidity buffer 10%.
        pool.setRiskLimits(125_000e6, 500e6, 25_000e6);

        // A quarter of every origination fee funds the reserve that absorbs bad debt before any of
        // it reaches providers. See docs/risk-parameters.md for why a quarter.
        pool.setReserveFeeShare(2_500);

        // A real tokenized asset with its real Chainlink feed, when one is passed in. The token and
        // the feed are addresses on the chain being deployed to, not something this script creates,
        // so the same path works on mainnet with a mainnet token and a mainnet feed.
        //
        // REAL_ASSET / REAL_FEED come from docs/asset-onboarding.md, which is where the checks that
        // produce them are written down. REAL_MAX_PRICE_AGE exists because a testnet feed is not
        // maintained at its mainnet heartbeat: see the runbook.
        address realAsset = vm.envOr("REAL_ASSET", address(0));
        if (realAsset != address(0)) {
            address realFeed = vm.envAddress("REAL_FEED");
            uint16 realLtv = uint16(vm.envOr("REAL_MAX_LTV_BPS", uint256(5500)));
            uint16 realThreshold = uint16(vm.envOr("REAL_LIQ_THRESHOLD_BPS", uint256(7000)));
            uint64 realMaxAge = uint64(vm.envOr("REAL_MAX_PRICE_AGE", uint256(1 days)));
            uint16 realDeviation = uint16(vm.envOr("REAL_MAX_DEVIATION_BPS", uint256(2000)));
            uint256 realMin = vm.envOr("REAL_MIN_PRICE", uint256(0));
            uint256 realMax = vm.envOr("REAL_MAX_PRICE", uint256(0));
            uint256 realDebtCap = vm.envOr("REAL_DEBT_CAP", uint256(37_500e6));
            uint256 realCollateralCap = vm.envOr("REAL_COLLATERAL_CAP", uint256(0));

            // Price is set to 0 here: the feed is the source, and configureAsset's manual price is
            // only a fallback for assets that have none.
            pool.configureAsset(realAsset, realLtv, realThreshold, 0);
            pool.setPriceFeed(realAsset, realFeed);
            pool.setPriceGuard(realAsset, realMaxAge, realDeviation, realMin, realMax);
            pool.setAssetCaps(realAsset, realDebtCap, realCollateralCap);
        }

        // The L2 sequencer uptime feed. Chainlink has not published one for Robinhood Chain, and its
        // documentation says it is no longer adding them to new networks; scripts/check-sequencer-feed.mjs
        // asks again every week and keeps the answer on #38. The day an address exists it is wired
        // here at deploy, or afterwards by the owner with setSequencerUptimeFeed, which needs neither a
        // redeploy nor the timelock.
        //
        // The grace period comes with it, never from a default: how long after the sequencer returns
        // before a price is trusted again is a decision. And the address is checked to be a status
        // feed before it is wired. A price feed pasted here by mistake answers something other than 0
        // or 1, which the pool reads as "sequencer down" — every price on every asset refused, from
        // the first block.
        _wireSequencerFeed(pool);

        PassportRegistry registry = new PassportRegistry();
        PartnershipDesk desk = new PartnershipDesk(address(usdc));

        // The brake, held by a key separate from the owner's. Passed in rather than derived, so the
        // guardian is a deliberate choice; with none given the owner can still pause, which is the
        // pre-existing authority rather than a new one.
        address guardian = vm.envOr("GUARDIAN", address(0));
        if (guardian != address(0)) {
            pool.setGuardian(guardian);
            desk.setGuardian(guardian);
        }

        // The auditor gates settlement on the desk, and setAuditor moves behind the timelock the
        // moment one is wired. Appointed here, before that, for the same reason the risk parameters
        // are: a deployment has to arrive configured, not configurable.
        address auditor = vm.envOr("AUDITOR", address(0));
        if (auditor != address(0)) desk.setAuditor(auditor);

        address deployer = vm.addr(deployerKey);
        registry.attest(deployer, 0x1f, 0);
        desk.createPartnership(deployer, 4000, 100_000e6, uint64(block.timestamp + 30 days), uint64(block.timestamp + 200 days));
        usdc.mint(deployer, 1_000_000e6);
        tbill.mint(deployer, 10_000e18);
        bnvda.mint(deployer, 1_000e18);
        tgold.mint(deployer, 100e18);

        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(250_000e6);
        // Seed the reserve so the first gap-down does not land on providers before fees have had
        // time to build it. 2% of pool size, per docs/risk-parameters.md.
        pool.fundReserve(5_000e6);

        // Handover, last, because everything above needs the owner to still hold the keys. Wire the
        // delay first so risk parameters are already behind it when ownership moves, then hand the
        // three contracts to the multisig. With no MULTISIG given the deployer keeps them, which is
        // the state a throwaway test deployment wants.
        address multisig = vm.envOr("MULTISIG", address(0));
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(0));
        // A throwaway deployment may keep the deployer. Mainnet may not: a stale environment file
        // there would leave every privileged surface on one key with nothing to say so.
        if (block.chainid == 4663) {
            require(multisig != address(0), "MULTISIG required on mainnet");
        }
        _wirePriceUpdater(pool);

        address timelockAddress;
        if (multisig != address(0)) {
            require(timelockDelay > 0, "TIMELOCK_DELAY required alongside MULTISIG");
            SafixTimelock timelock = new SafixTimelock(multisig, timelockDelay);
            timelockAddress = address(timelock);
            pool.setTimelock(timelockAddress);
            desk.setTimelock(timelockAddress);
            pool.setOwner(multisig);
            registry.setOwner(multisig);
            desk.setOwner(multisig);
        }

        vm.stopBroadcast();

        console.log("usdc", address(usdc));
        console.log("tbill", address(tbill));
        console.log("bnvda", address(bnvda));
        console.log("tgold", address(tgold));
        console.log("pool", address(pool));
        console.log("registry", address(registry));
        console.log("desk", address(desk));
        console.log("guardian", guardian);
        console.log("multisig", multisig);
        console.log("timelock", timelockAddress);
        console.log("realAsset", realAsset);
        console.log("auditor", auditor);
    }


    /// @dev Leaves the pool with a way to price something before ownership moves.
    ///
    ///      Ownership goes to a multisig at the end of this script, and `setPriceUpdater` is
    ///      `onlyOwner`. Appointing one afterwards therefore costs a round of signatures, and
    ///      every asset ages into a stale price while they are collected: no draw, no liquidation,
    ///      no withdrawal against collateral, with the protocol open and inert. Nothing is at risk,
    ///      because refusing a price is the safe direction, but the first thing anybody sees is a
    ///      screen that refuses. It cost a Safe round trip on testnet already.
    ///
    ///      Mainnet must therefore arrive with one of the two ways to price an asset in place. A
    ///      feed on every asset is the better one and retires the manual updater, so either
    ///      satisfies this and neither is assumed.
    function _wirePriceUpdater(SafixPool pool) internal {
        address priceUpdater = vm.envOr("PRICE_UPDATER", address(0));
        if (priceUpdater != address(0)) pool.setPriceUpdater(priceUpdater);
        if (block.chainid != 4663) return;

        require(priceUpdater != address(0) || _everyAssetHasAFeed(pool), "mainnet needs a price updater or a feed on every asset");
    }

    /// @dev Whether every configured asset carries a Chainlink feed, which is what makes a manual
    ///      price updater unnecessary rather than merely absent.
    function _everyAssetHasAFeed(SafixPool pool) internal view returns (bool) {
        uint256 count = pool.assetCount();
        if (count == 0) return false;
        for (uint256 i = 0; i < count; i++) {
            if (pool.priceFeeds(pool.assetList(i)) == address(0)) return false;
        }
        return true;
    }

    /// @dev Wires the L2 sequencer uptime feed when one is given. Kept out of `run`, which already
    ///      holds as many locals as the stack allows.
    function _wireSequencerFeed(SafixPool pool) internal {
        address sequencerFeed = vm.envOr("SEQUENCER_UPTIME_FEED", address(0));
        if (sequencerFeed == address(0)) return;
        uint256 sequencerGrace = vm.envOr("SEQUENCER_GRACE_PERIOD", uint256(0));
        require(sequencerGrace > 0, "SEQUENCER_GRACE_PERIOD required alongside SEQUENCER_UPTIME_FEED");
        (, int256 sequencerStatus, uint256 statusSince,,) = IAggregatorV3(sequencerFeed).latestRoundData();
        require(sequencerStatus == 0 || sequencerStatus == 1, "SEQUENCER_UPTIME_FEED is not a status feed");
        require(statusSince > 0, "SEQUENCER_UPTIME_FEED has never reported");
        pool.setSequencerUptimeFeed(sequencerFeed, sequencerGrace);
    }
}
