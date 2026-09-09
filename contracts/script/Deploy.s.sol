// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SafixPool} from "../src/SafixPool.sol";
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

        // The L2 sequencer uptime feed is deliberately left unset: Chainlink has not published one
        // for Robinhood Chain. setSequencerUptimeFeed wires it the day one exists, with no redeploy.

        PassportRegistry registry = new PassportRegistry();
        PartnershipDesk desk = new PartnershipDesk(address(usdc));

        address deployer = vm.addr(deployerKey);
        registry.attest(deployer, 0x1f, 0);
        desk.createPartnership(deployer, 4000, 100_000e6, uint64(block.timestamp + 30 days));
        usdc.mint(deployer, 1_000_000e6);
        tbill.mint(deployer, 10_000e18);
        bnvda.mint(deployer, 1_000e18);
        tgold.mint(deployer, 100e18);

        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(250_000e6);

        vm.stopBroadcast();

        console.log("usdc", address(usdc));
        console.log("tbill", address(tbill));
        console.log("bnvda", address(bnvda));
        console.log("tgold", address(tgold));
        console.log("pool", address(pool));
        console.log("registry", address(registry));
        console.log("desk", address(desk));
    }
}
