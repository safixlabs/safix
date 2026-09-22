// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {SafixTimelock} from "../src/SafixTimelock.sol";

/**
 * Retiring an asset without stranding what is already borrowed against it.
 *
 * An asset outlives its usefulness: the stock behind it is delisted, its token is
 * compromised, its feed is retired. The pool has to be able to stop taking more of
 * it without losing the ability to get out of what it already holds, and the two
 * obvious levers both fail at that. A zero cap means uncapped, so it opens the
 * asset rather than closing it. Clearing `enabled` takes the price down with it,
 * and an asset with no price cannot be liquidated, which turns a bad asset into
 * bad debt nobody can clear.
 */
contract AssetRetirementTest is Test {
    SafixPool internal pool;
    SafixTimelock internal timelock;
    MockERC20 internal usdc;
    MockERC20 internal bnvda;

    address internal provider = makeAddr("provider");
    address internal borrower = makeAddr("borrower");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        bnvda = new MockERC20("Tokenized Nvidia", "bNVDA", 18);
        pool = new SafixPool(address(usdc));
        timelock = new SafixTimelock(address(this), 2 days);
        pool.configureAsset(address(bnvda), 5500, 7000, 172e18);

        usdc.mint(provider, 1_000_000e6);
        bnvda.mint(borrower, 1_000e18);
        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(provider);
        pool.deposit(500_000e6);
        vm.prank(borrower);
        bnvda.approve(address(pool), type(uint256).max);

        vm.startPrank(borrower);
        pool.lockCollateral(address(bnvda), 100e18);
        pool.draw(address(bnvda), 5_000e6);
        vm.stopPrank();
    }

    function _retire(bool retired) internal {
        if (pool.timelock() != address(timelock)) pool.setTimelock(address(timelock));
        timelock.queue(address(pool), abi.encodeCall(SafixPool.setAssetRetired, (address(bnvda), retired)), bytes32(0));
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(pool), abi.encodeCall(SafixPool.setAssetRetired, (address(bnvda), retired)), bytes32(0));
    }

    function testRetiringStopsNewExposureAndNothingElse() public {
        _retire(true);
        assertTrue(pool.assetRetired(address(bnvda)));

        vm.startPrank(borrower);
        vm.expectRevert("asset retired");
        pool.lockCollateral(address(bnvda), 1e18);
        vm.expectRevert("asset retired");
        pool.draw(address(bnvda), 100e6);
        vm.stopPrank();

        // What is already outstanding has to keep moving, or retiring an asset would
        // be a way of trapping the people holding it.
        (, uint256 debtBefore,) = pool.positions(borrower, address(bnvda));
        assertGt(debtBefore, 0);

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(address(bnvda), 1_000e6);
        pool.withdrawCollateral(address(bnvda), 1e18);
        vm.stopPrank();

        (, uint256 debtAfter,) = pool.positions(borrower, address(bnvda));
        assertLt(debtAfter, debtBefore);
    }

    function testARetiredAssetIsStillLiquidatable() public {
        _retire(true);

        // The reason retirement does not clear `enabled`: a price is still needed,
        // and without one the pool could never close a position that has gone under.
        pool.setPrice(address(bnvda), 60e18);
        assertTrue(pool.isLiquidatable(borrower, address(bnvda)));

        (, uint256 debt,) = pool.positions(borrower, address(bnvda));
        vm.prank(keeper);
        pool.liquidate(borrower, address(bnvda), debt);

        (uint256 collateral, uint256 remaining,) = pool.positions(borrower, address(bnvda));
        assertEq(remaining, 0);
        assertEq(collateral, 0);
    }

    function testRetirementCanBeLifted() public {
        _retire(true);
        vm.prank(borrower);
        vm.expectRevert("asset retired");
        pool.draw(address(bnvda), 100e6);

        _retire(false);
        assertFalse(pool.assetRetired(address(bnvda)));
        vm.prank(borrower);
        pool.draw(address(bnvda), 100e6);
    }

    function testOnlyTheTimelockCanRetireAnAsset() public {
        // The deployer holds the role until it is handed over, which is how the
        // deploy configures a pool before anybody else can reach it.
        pool.setAssetRetired(address(bnvda), true);
        assertTrue(pool.assetRetired(address(bnvda)));

        pool.setTimelock(address(timelock));
        vm.expectRevert("not timelock");
        pool.setAssetRetired(address(bnvda), false);

        vm.prank(borrower);
        vm.expectRevert("not timelock");
        pool.setAssetRetired(address(bnvda), false);
    }

    function testAnAssetThatWasNeverConfiguredCannotBeRetired() public {
        MockERC20 stranger = new MockERC20("Elsewhere", "ELS", 18);
        if (pool.timelock() != address(timelock)) pool.setTimelock(address(timelock));
        bytes memory call = abi.encodeCall(SafixPool.setAssetRetired, (address(stranger), true));
        timelock.queue(address(pool), call, bytes32(0));
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert("asset off");
        timelock.execute(address(pool), call, bytes32(0));
    }
}
