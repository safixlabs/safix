// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Every boundary the caps draw, tested from both sides: the last accepted value and the
///         first refused one. Also the bookkeeping behind them, since a cap is only as good as the
///         accumulator it reads.
contract RiskCapsTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal tbill;
    MockERC20 internal bnvda;

    address internal provider = makeAddr("provider");
    address internal borrower = makeAddr("borrower");
    address internal borrowerTwo = makeAddr("borrowerTwo");
    address internal keeper = makeAddr("keeper");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant FEE_BPS = 50;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        bnvda = new MockERC20("Tokenized Nvidia", "bNVDA", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);
        pool.configureAsset(address(bnvda), 5500, 7000, 100e18);

        usdc.mint(provider, 10_000_000e6);
        usdc.mint(borrower, 1_000_000e6);
        usdc.mint(borrowerTwo, 1_000_000e6);
        tbill.mint(borrower, 100_000e18);
        tbill.mint(borrowerTwo, 100_000e18);
        bnvda.mint(borrower, 100_000e18);

        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? borrower : borrowerTwo;
            vm.startPrank(who);
            usdc.approve(address(pool), type(uint256).max);
            tbill.approve(address(pool), type(uint256).max);
            bnvda.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }

        vm.prank(provider);
        pool.deposit(1_000_000e6);
    }

    /// @dev Debt added by drawing `amount`, fee included, which is what the caps measure.
    function _debtFor(uint256 amount) internal pure returns (uint256) {
        return amount + (amount * FEE_BPS) / 10_000;
    }

    /// @dev The draw whose debt lands exactly on `targetDebt`.
    function _drawForDebt(uint256 targetDebt) internal pure returns (uint256) {
        return (targetDebt * 10_000) / (10_000 + FEE_BPS);
    }

    // --------------------------------------------------------------------------------------
    // per-asset debt cap
    // --------------------------------------------------------------------------------------

    function testDebtCapAcceptsTheBoundaryAndRefusesOneAbove() public {
        // The cap is set from the draw rather than the other way round, so the boundary is exact:
        // integer division on the fee makes the inverse ambiguous by a unit.
        uint256 draw = 10_000e6;
        uint256 cap = _debtFor(draw);

        pool.setAssetCaps(address(tbill), cap - 1, 0);
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 1_000e18);
        vm.expectRevert(bytes("asset cap"));
        pool.draw(address(tbill), draw);
        vm.stopPrank();

        pool.setAssetCaps(address(tbill), cap, 0);
        vm.prank(borrower);
        pool.draw(address(tbill), draw);

        assertEq(pool.assetDebt(address(tbill)), cap);
        assertEq(pool.assetDebtHeadroom(address(tbill)), 0);
    }

    function testDebtCapIsSharedAcrossBorrowers() public {
        pool.setAssetCaps(address(tbill), 10_000e6, 0);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 1_000e18);
        pool.draw(address(tbill), 8_000e6);
        vm.stopPrank();

        // The cap is the asset's, not each borrower's: what one draws, another cannot.
        vm.startPrank(borrowerTwo);
        pool.lockCollateral(address(tbill), 1_000e18);
        vm.expectRevert(bytes("asset cap"));
        pool.draw(address(tbill), 2_000e6);
        pool.draw(address(tbill), 1_000e6);
        vm.stopPrank();
    }

    function testDebtCapIsPerAssetNotPooled() public {
        pool.setAssetCaps(address(tbill), 5_000e6, 0);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 1_000e18);
        pool.lockCollateral(address(bnvda), 1_000e18);
        pool.draw(address(tbill), 4_000e6);

        vm.expectRevert(bytes("asset cap"));
        pool.draw(address(tbill), 2_000e6);

        // bNVDA is uncapped, so tBILL being full says nothing about it.
        pool.draw(address(bnvda), 20_000e6);
        vm.stopPrank();

        assertEq(pool.assetDebt(address(bnvda)), _debtFor(20_000e6));
    }

    function testRepayingFreesRoomUnderTheCap() public {
        pool.setAssetCaps(address(tbill), 10_000e6, 0);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 1_000e18);
        pool.draw(address(tbill), 9_900e6);
        vm.expectRevert(bytes("asset cap"));
        pool.draw(address(tbill), 100e6);

        pool.repay(address(tbill), 5_000e6);
        pool.draw(address(tbill), 100e6);
        vm.stopPrank();
    }

    function testZeroDebtCapMeansUncapped() public {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100_000e18);
        pool.draw(address(tbill), 500_000e6);
        vm.stopPrank();
        assertEq(pool.assetDebtHeadroom(address(tbill)), type(uint256).max);
    }

    // --------------------------------------------------------------------------------------
    // per-asset collateral cap
    // --------------------------------------------------------------------------------------

    function testCollateralCapAcceptsTheBoundaryAndRefusesOneAbove() public {
        pool.setAssetCaps(address(tbill), 0, 100e18);

        vm.startPrank(borrower);
        vm.expectRevert(bytes("collateral cap"));
        pool.lockCollateral(address(tbill), 100e18 + 1);

        pool.lockCollateral(address(tbill), 100e18);
        assertEq(pool.assetCollateralHeadroom(address(tbill)), 0);

        vm.expectRevert(bytes("collateral cap"));
        pool.lockCollateral(address(tbill), 1);
        vm.stopPrank();
    }

    function testWithdrawingCollateralFreesRoomUnderTheCap() public {
        pool.setAssetCaps(address(tbill), 0, 100e18);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.withdrawCollateral(address(tbill), 40e18);
        assertEq(pool.assetCollateral(address(tbill)), 60e18);
        pool.lockCollateral(address(tbill), 40e18);
        vm.stopPrank();
        assertEq(pool.assetCollateral(address(tbill)), 100e18);
    }

    // --------------------------------------------------------------------------------------
    // global debt ceiling
    // --------------------------------------------------------------------------------------

    function testGlobalCeilingBindsAcrossAssets() public {
        pool.setRiskLimits(30_000e6, 0, 0);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 1_000e18);
        pool.lockCollateral(address(bnvda), 1_000e18);
        pool.draw(address(tbill), 20_000e6);

        // Neither asset is capped; the pool as a whole is.
        vm.expectRevert(bytes("global cap"));
        pool.draw(address(bnvda), 10_000e6);

        pool.draw(address(bnvda), 9_000e6);
        vm.stopPrank();

        assertEq(pool.totalDebt(), _debtFor(20_000e6) + _debtFor(9_000e6));
        assertLe(pool.totalDebt(), 30_000e6);
    }

    function testGlobalCeilingBoundaryIsExact() public {
        uint256 draw = 10_000e6;
        uint256 ceiling = _debtFor(draw);

        pool.setRiskLimits(ceiling - 1, 0, 0);
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 1_000e18);
        vm.expectRevert(bytes("global cap"));
        pool.draw(address(tbill), draw);
        vm.stopPrank();

        pool.setRiskLimits(ceiling, 0, 0);
        vm.prank(borrower);
        pool.draw(address(tbill), draw);

        assertEq(pool.totalDebt(), ceiling);
        assertEq(pool.globalDebtHeadroom(), 0);
    }

    function testZeroCeilingMeansUncapped() public view {
        assertEq(pool.globalDebtHeadroom(), type(uint256).max);
    }

    // --------------------------------------------------------------------------------------
    // minimum position size
    // --------------------------------------------------------------------------------------

    function testDrawBelowTheMinimumIsRefused() public {
        uint256 draw = 1_000e6;
        uint256 minimum = _debtFor(draw);
        pool.setRiskLimits(0, minimum, 0);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 1_000e18);

        // One unit short of the floor.
        vm.expectRevert(bytes("position too small"));
        pool.draw(address(tbill), draw - 1);

        // Exactly on it.
        pool.draw(address(tbill), draw);
        vm.stopPrank();

        (, uint256 debt,) = pool.positions(borrower, address(tbill));
        assertEq(debt, minimum);
    }

    function testRepayingToDustIsRefusedButRepayingInFullIsNot() public {
        pool.setRiskLimits(0, 1_000e6, 0);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 1_000e18);
        pool.draw(address(tbill), 5_000e6);
        (, uint256 debt,) = pool.positions(borrower, address(tbill));

        // Leaving 1 unit behind would be dust.
        vm.expectRevert(bytes("position too small"));
        pool.repay(address(tbill), debt - 1);

        // Leaving exactly the minimum is fine.
        pool.repay(address(tbill), debt - 1_000e6);

        // And clearing it entirely is always allowed.
        (, uint256 remaining,) = pool.positions(borrower, address(tbill));
        pool.repay(address(tbill), remaining);
        vm.stopPrank();

        (, uint256 finalDebt,) = pool.positions(borrower, address(tbill));
        assertEq(finalDebt, 0);
    }

    function testClosePositionIsNeverBlockedByTheMinimum() public {
        pool.setRiskLimits(0, 1_000e6, 0);
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 1_000e18);
        pool.draw(address(tbill), 5_000e6);
        // The exit does not consult the floor at all.
        pool.closePosition(address(tbill));
        vm.stopPrank();
        (uint256 collateral, uint256 debt,) = pool.positions(borrower, address(tbill));
        assertEq(collateral, 0);
        assertEq(debt, 0);
    }

    function testPartialLiquidationThatWouldLeaveDustTakesTheWholePosition() public {
        pool.setRiskLimits(0, 1_000e6, 0);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.draw(address(tbill), 5_000e6);
        vm.stopPrank();
        pool.setPrice(address(tbill), 55e18);

        (, uint256 debt,) = pool.positions(borrower, address(tbill));

        // Ask for an offset that would leave less than the minimum behind.
        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), debt - 500e6);

        (uint256 collateralAfter, uint256 debtAfter,) = pool.positions(borrower, address(tbill));
        assertEq(debtAfter, 0, "dust left behind");
        assertEq(collateralAfter, 0);
        assertEq(pool.assetDebt(address(tbill)), 0);
        assertEq(pool.totalDebt(), 0);
    }

    function testPartialLiquidationLeavingEnoughStaysPartial() public {
        pool.setRiskLimits(0, 1_000e6, 0);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.draw(address(tbill), 5_000e6);
        vm.stopPrank();
        pool.setPrice(address(tbill), 55e18);

        (, uint256 debt,) = pool.positions(borrower, address(tbill));
        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), 2_000e6);

        (, uint256 debtAfter,) = pool.positions(borrower, address(tbill));
        assertEq(debtAfter, debt - 2_000e6);
        assertGe(debtAfter, 1_000e6);
    }

    // --------------------------------------------------------------------------------------
    // minimum liquidity buffer
    // --------------------------------------------------------------------------------------

    function testDrawCannotTakeLiquidityBelowTheBuffer() public {
        uint256 available = pool.availableLiquidity();
        uint256 buffer = available - 10_000e6;
        pool.setRiskLimits(0, 0, buffer);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100_000e18);
        assertEq(pool.drawableLiquidity(), 10_000e6);

        // The draw plus its fee is what leaves the lendable pool, so the largest safe draw is the
        // one whose debt equals the headroom.
        uint256 largestDraw = _drawForDebt(10_000e6);
        vm.expectRevert(bytes("illiquid"));
        pool.draw(address(tbill), largestDraw + 100);

        pool.draw(address(tbill), largestDraw);
        vm.stopPrank();

        // The buffer survived: liquidity never went under the floor.
        assertGe(pool.availableLiquidity(), buffer, "buffer was breached");
    }

    function testProvidersCanStillWithdrawThroughTheBuffer() public {
        pool.setRiskLimits(0, 0, pool.availableLiquidity() - 1_000e6);
        // The buffer bounds borrowing, not the providers whose money it is.
        vm.prank(provider);
        pool.withdraw(500_000e6);
        assertEq(pool.compoundedDepositOf(provider), 500_000e6);
    }

    // --------------------------------------------------------------------------------------
    // bookkeeping the caps depend on
    // --------------------------------------------------------------------------------------

    function testAccumulatorsTrackThePositionsThatFeedThem() public {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 200e18);
        pool.draw(address(tbill), 5_000e6);
        vm.stopPrank();
        vm.startPrank(borrowerTwo);
        pool.lockCollateral(address(tbill), 300e18);
        pool.draw(address(tbill), 3_000e6);
        vm.stopPrank();

        (uint256 c1, uint256 d1,) = pool.positions(borrower, address(tbill));
        (uint256 c2, uint256 d2,) = pool.positions(borrowerTwo, address(tbill));
        assertEq(pool.assetCollateral(address(tbill)), c1 + c2);
        assertEq(pool.assetDebt(address(tbill)), d1 + d2);
        assertEq(pool.totalDebt(), d1 + d2);

        // And they unwind exactly.
        vm.prank(borrower);
        pool.closePosition(address(tbill));
        vm.prank(borrowerTwo);
        pool.closePosition(address(tbill));
        assertEq(pool.assetCollateral(address(tbill)), 0);
        assertEq(pool.assetDebt(address(tbill)), 0);
        assertEq(pool.totalDebt(), 0);
    }

    function testLiquidationUnwindsTheAccumulators() public {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.draw(address(tbill), 5_000e6);
        vm.stopPrank();
        pool.setPrice(address(tbill), 55e18);

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        assertEq(pool.assetDebt(address(tbill)), 0);
        assertEq(pool.assetCollateral(address(tbill)), 0);
        assertEq(pool.totalDebt(), 0);
    }

    // --------------------------------------------------------------------------------------
    // configuring the caps
    // --------------------------------------------------------------------------------------

    function testReconfiguringAnAssetKeepsItsCaps() public {
        pool.setAssetCaps(address(tbill), 10_000e6, 500e18);
        // Tuning the LTV must not silently drop the caps that bound the asset.
        pool.configureAsset(address(tbill), 7000, 8500, 100e18);
        (,,,, uint256 debtCap, uint256 collateralCap) = pool.assetConfig(address(tbill));
        assertEq(debtCap, 10_000e6);
        assertEq(collateralCap, 500e18);
    }

    function testLoweringACapBelowCurrentUseStopsGrowthWithoutForcingAnUnwind() public {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 1_000e18);
        pool.draw(address(tbill), 20_000e6);
        vm.stopPrank();

        // The cap comes down below what is already outstanding.
        pool.setAssetCaps(address(tbill), 5_000e6, 0);
        assertEq(pool.assetDebtHeadroom(address(tbill)), 0);

        vm.prank(borrower);
        vm.expectRevert(bytes("asset cap"));
        pool.draw(address(tbill), 1e6);

        // The existing position is untouched and can still be exited normally.
        vm.prank(borrower);
        pool.repay(address(tbill), 1_000e6);
        vm.prank(borrower);
        pool.closePosition(address(tbill));
    }

    function testOnlyOwnerSetsCapsAndLimits() public {
        vm.startPrank(outsider);
        vm.expectRevert(bytes("not timelock"));
        pool.setAssetCaps(address(tbill), 1, 1);
        vm.expectRevert(bytes("not timelock"));
        pool.setRiskLimits(1, 1, 1);
        vm.stopPrank();
    }

    function testCapsCannotBeSetOnAnUnconfiguredAsset() public {
        vm.expectRevert(bytes("asset off"));
        pool.setAssetCaps(makeAddr("unconfigured"), 1, 1);
    }

    function testHeadroomViewsReportWhatTheDrawPathEnforces() public {
        pool.setAssetCaps(address(tbill), 10_000e6, 500e18);
        pool.setRiskLimits(50_000e6, 0, 0);

        assertEq(pool.assetDebtHeadroom(address(tbill)), 10_000e6);
        assertEq(pool.assetCollateralHeadroom(address(tbill)), 500e18);
        assertEq(pool.globalDebtHeadroom(), 50_000e6);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 200e18);
        pool.draw(address(tbill), 4_000e6);
        vm.stopPrank();

        uint256 debtUsed = _debtFor(4_000e6);
        assertEq(pool.assetDebtHeadroom(address(tbill)), 10_000e6 - debtUsed);
        assertEq(pool.assetCollateralHeadroom(address(tbill)), 300e18);
        assertEq(pool.globalDebtHeadroom(), 50_000e6 - debtUsed);

        // The headroom the view reports is exactly what the draw path will accept: a draw whose
        // debt is one unit past it is refused, and one that lands on it is not.
        uint256 headroom = pool.assetDebtHeadroom(address(tbill));
        vm.prank(borrower);
        vm.expectRevert(bytes("asset cap"));
        pool.draw(address(tbill), _drawForDebt(headroom) + 100);

        vm.prank(borrower);
        pool.draw(address(tbill), _drawForDebt(headroom));
        assertLe(pool.assetDebt(address(tbill)), 10_000e6);
    }
}
