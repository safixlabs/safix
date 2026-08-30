// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        MockERC20 usdc = new MockERC20("Safix Test USD", "tUSDC", 6);
        MockERC20 tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        MockERC20 bnvda = new MockERC20("Tokenized Nvidia", "bNVDA", 18);
        MockERC20 tgold = new MockERC20("Tokenized gold", "tGOLD", 18);

        SafixPool pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100.42e18);
        pool.configureAsset(address(bnvda), 5500, 7000, 172.35e18);
        pool.configureAsset(address(tgold), 6500, 8000, 3392.8e18);

        address deployer = vm.addr(deployerKey);
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
    }
}
