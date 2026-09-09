// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {PassportRegistry} from "../src/PassportRegistry.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract SafixPoolTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal tbill;

    address internal provider = makeAddr("provider");
    address internal providerTwo = makeAddr("providerTwo");
    address internal borrower = makeAddr("borrower");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);

        usdc.mint(provider, 1_000_000e6);
        usdc.mint(providerTwo, 1_000_000e6);
        usdc.mint(borrower, 100_000e6);
        tbill.mint(borrower, 1_000e18);

        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(providerTwo);
        usdc.approve(address(pool), type(uint256).max);
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        tbill.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _seedPool(uint256 amount) internal {
        vm.prank(provider);
        pool.deposit(amount);
    }

    function _openPosition(uint256 collateral, uint256 drawAmount) internal {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), collateral);
        pool.draw(address(tbill), drawAmount);
        vm.stopPrank();
    }

    function testDepositAndWithdraw() public {
        _seedPool(50_000e6);
        assertEq(pool.totalDeposits(), 50_000e6);
        assertEq(pool.compoundedDepositOf(provider), 50_000e6);

        vm.prank(provider);
        pool.withdraw(20_000e6);
        assertEq(pool.compoundedDepositOf(provider), 30_000e6);
        assertEq(usdc.balanceOf(provider), 970_000e6);
    }

    function testDrawChargesOneTimeFee() public {
        _seedPool(50_000e6);
        _openPosition(100e18, 5_000e6);

        (, uint256 debt, uint256 totalDrawn) = pool.positions(borrower, address(tbill));
        assertEq(debt, 5_025e6);
        assertEq(totalDrawn, 5_000e6);
        assertEq(pool.protocolFees(), 25e6);
        assertEq(usdc.balanceOf(borrower), 105_000e6);
    }

    function testDrawRespectsMaxLtv() public {
        _seedPool(50_000e6);
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        vm.expectRevert(bytes("exceeds ltv"));
        pool.draw(address(tbill), 8_000e6);
        vm.stopPrank();
    }

    function testRepayAndClosePosition() public {
        _seedPool(50_000e6);
        _openPosition(100e18, 5_000e6);

        vm.startPrank(borrower);
        pool.repay(address(tbill), 2_000e6);
        (, uint256 debtAfterRepay,) = pool.positions(borrower, address(tbill));
        assertEq(debtAfterRepay, 3_025e6);

        pool.closePosition(address(tbill));
        vm.stopPrank();

        (uint256 collateral, uint256 debt, uint256 totalDrawn) = pool.positions(borrower, address(tbill));
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(totalDrawn, 0);
        assertEq(tbill.balanceOf(borrower), 1_000e18);
        assertEq(pool.protocolFees(), 25e6 + 15e6);
    }

    function testCannotDrainCollateralWhileInDebt() public {
        _seedPool(50_000e6);
        _openPosition(100e18, 5_000e6);

        vm.prank(borrower);
        vm.expectRevert(bytes("would break ltv"));
        pool.withdrawCollateral(address(tbill), 40e18);

        vm.prank(borrower);
        vm.expectRevert(bytes("close position instead"));
        pool.withdrawCollateral(address(tbill), 100e18);
    }

    function testLiquidationDistributesGainsAndLosses() public {
        _seedPool(40_000e6);
        vm.prank(providerTwo);
        pool.deposit(10_000e6);

        _openPosition(100e18, 5_000e6);
        pool.setPrice(address(tbill), 55e18);
        assertTrue(pool.isLiquidatable(borrower, address(tbill)));

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        (uint256 collateral, uint256 debt,) = pool.positions(borrower, address(tbill));
        assertEq(collateral, 0);
        assertEq(debt, 0);

        assertEq(tbill.balanceOf(keeper), 0.5e18);
        assertApproxEqAbs(pool.compoundedDepositOf(provider), 35_980e6, 1);
        assertApproxEqAbs(pool.compoundedDepositOf(providerTwo), 8_995e6, 1);
        assertApproxEqAbs(pool.gainOf(provider, address(tbill)), 79.6e18, 1e12);
        assertApproxEqAbs(pool.gainOf(providerTwo, address(tbill)), 19.9e18, 1e12);

        uint256 balanceBefore = tbill.balanceOf(provider);
        address[] memory assets = new address[](1);
        assets[0] = address(tbill);
        vm.prank(provider);
        pool.claimGains(assets);
        assertApproxEqAbs(tbill.balanceOf(provider) - balanceBefore, 79.6e18, 1e12);
    }

    function testPriceUpdaterRole() public {
        pool.setPriceUpdater(keeper);
        vm.prank(keeper);
        pool.setPrice(address(tbill), 99e18);
        (,,, uint256 price,,) = pool.assetConfig(address(tbill));
        assertEq(price, 99e18);

        vm.prank(borrower);
        vm.expectRevert(bytes("not price updater"));
        pool.setPrice(address(tbill), 1e18);
    }

    function testStalePriceBlocksDrawAndLiquidate() public {
        _seedPool(50_000e6);
        pool.setPriceGuard(address(tbill), 1 hours, 0, 0, 0);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(bytes("stale price"));
        pool.draw(address(tbill), 1_000e6);
        vm.stopPrank();

        pool.setPrice(address(tbill), 100e18);
        vm.prank(borrower);
        pool.draw(address(tbill), 1_000e6);
    }

    function testPassportGate() public {
        _seedPool(50_000e6);
        PassportRegistry registry = new PassportRegistry();
        pool.setPassportRegistry(address(registry));

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        vm.expectRevert(bytes("passport required"));
        pool.draw(address(tbill), 1_000e6);
        vm.stopPrank();

        registry.attest(borrower, 0x1f, 0);
        vm.prank(borrower);
        pool.draw(address(tbill), 1_000e6);

        registry.revoke(borrower);
        vm.prank(borrower);
        vm.expectRevert(bytes("passport required"));
        pool.draw(address(tbill), 100e6);
    }

    function testLiquidateRevertsWhenHealthy() public {
        _seedPool(50_000e6);
        _openPosition(100e18, 5_000e6);
        vm.expectRevert(bytes("healthy"));
        pool.liquidate(borrower, address(tbill), type(uint256).max);
    }

    function testOnlyOwnerGuards() public {
        vm.startPrank(keeper);
        vm.expectRevert(bytes("not owner"));
        pool.configureAsset(address(tbill), 5000, 6000, 1e18);
        vm.expectRevert(bytes("not price updater"));
        pool.setPrice(address(tbill), 1e18);
        vm.expectRevert(bytes("not owner"));
        pool.collectProtocolFees(keeper);
        vm.stopPrank();
    }

    function testFullLiquidationClearsTotalDrawn() public {
        _seedPool(50_000e6);
        _openPosition(100e18, 5_000e6);
        pool.setPrice(address(tbill), 55e18);

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        (uint256 collateral, uint256 debt, uint256 totalDrawn) = pool.positions(borrower, address(tbill));
        assertEq(collateral, 0);
        assertEq(debt, 0);
        // Nothing of the position survives, so nothing is left to charge a redemption fee on.
        assertEq(totalDrawn, 0);
    }

    function testPartialLiquidationReducesTotalDrawnProRata() public {
        _seedPool(50_000e6);
        _openPosition(100e18, 5_000e6);
        pool.setPrice(address(tbill), 55e18);

        (, uint256 debtBefore, uint256 drawnBefore) = pool.positions(borrower, address(tbill));
        uint256 offset = debtBefore / 4;

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), offset);

        (, uint256 debtAfter, uint256 drawnAfter) = pool.positions(borrower, address(tbill));
        assertEq(debtAfter, debtBefore - offset);
        // Drawn principal falls by the same share of the position the liquidation took.
        assertEq(drawnAfter, drawnBefore - (drawnBefore * offset) / debtBefore);
    }

    function testRedemptionFeeIgnoresLiquidatedDraws() public {
        _seedPool(50_000e6);
        _openPosition(100e18, 5_000e6);
        pool.setPrice(address(tbill), 55e18);

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);
        pool.setPrice(address(tbill), 100e18);
        uint256 feesAfterLiquidation = pool.protocolFees();

        // A fresh position on the same asset must not inherit the liquidated position's draws.
        _openPosition(100e18, 1_000e6);
        vm.prank(borrower);
        pool.closePosition(address(tbill));

        uint256 originationFee = (uint256(1_000e6) * pool.originationFeeBps()) / 10_000;
        uint256 redemptionFee = (uint256(1_000e6) * pool.redemptionFeeBps()) / 10_000;
        assertEq(pool.protocolFees() - feesAfterLiquidation, originationFee + redemptionFee);
    }

    function testCollectProtocolFees() public {
        _seedPool(50_000e6);
        _openPosition(100e18, 5_000e6);
        pool.collectProtocolFees(address(this));
        assertEq(usdc.balanceOf(address(this)), 25e6);
        assertEq(pool.protocolFees(), 0);
    }
}
