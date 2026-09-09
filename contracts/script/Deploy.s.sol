// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {SafixTimelock} from "../src/SafixTimelock.sol";
import {PartnershipDesk} from "../src/PartnershipDesk.sol";
import {PassportRegistry} from "../src/PassportRegistry.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
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

        // The L2 sequencer uptime feed is deliberately left unset: Chainlink has not published one
        // for Robinhood Chain. setSequencerUptimeFeed wires it the day one exists, with no redeploy.

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

        address deployer = vm.addr(deployerKey);
        registry.attest(deployer, 0x1f, 0);
        desk.createPartnership(deployer, 4000, 100_000e6, uint64(block.timestamp + 30 days));
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
    }
}
