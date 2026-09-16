// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice The redemption fee's basis (#33).
///
/// The fee used to be charged at close on every unit ever drawn, while `repay` shrank the debt and
/// left that base where it was. A liquidation took its share of the base by the ratio of base to
/// debt, which a repayment had made unbounded: late in a position's life one liquidation could
/// retire far more fee base than the debt it settled, and a borrower could be their own liquidator
/// to walk out of the fee. The base is now outstanding principal. Paying principal back — by a
/// repayment or at close — pays the redemption fee on it. A liquidation retires principal in
/// proportion, without a fee, and because principal never exceeds debt it can never retire more
/// than it settles.
contract FeeBasisTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal tbill;

    address internal provider = makeAddr("provider");
    address internal borrower = makeAddr("borrower");

    uint256 internal constant BPS = 10_000;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        // The issue's setup: 100 tBILL at $100, 8000 max LTV, 9000 threshold, one provider at 100,000.
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);

        usdc.mint(provider, 100_000e6);
        usdc.mint(borrower, 100_000e6);
        tbill.mint(borrower, 100e18);
        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        tbill.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.prank(provider);
        pool.deposit(100_000e6);
        vm.prank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
    }

    function _position() internal view returns (uint256 collateral, uint256 debt, uint256 principal) {
        return pool.positions(borrower, address(tbill));
    }

    function _redemptionFee(uint256 principal) internal view returns (uint256) {
        return (principal * pool.redemptionFeeBps()) / BPS;
    }

    function _assertPrincipalWithinDebt() internal view {
        (, uint256 debt, uint256 principal) = _position();
        assertLe(principal, debt, "principal exceeded the debt it is part of");
    }

    /// @dev The issue's position: 7,960 drawn and 7,950 repaid, collateral withdrawn to 0.63 tBILL,
    ///      which the LTV permits, then an ordinary 13% dip that makes it liquidatable.
    function _repayThenThin() internal {
        vm.startPrank(borrower);
        pool.repay(address(tbill), 7_950e6);
        (uint256 collateral,,) = _position();
        pool.withdrawCollateral(address(tbill), collateral - 0.63e18);
        vm.stopPrank();
        pool.setPrice(address(tbill), 87e18);
        assertTrue(pool.isLiquidatable(borrower, address(tbill)), "setup: the dip makes it liquidatable");
    }

    // --------------------------------------------------------------------------------------
    // the issue's two measurements
    // --------------------------------------------------------------------------------------

    function testALiquidationAfterARepaymentRetiresNoMoreFeeBaseThanTheDebtItSettles() public {
        vm.prank(borrower);
        pool.draw(address(tbill), 7_960e6);
        _repayThenThin();

        (, uint256 debtBefore, uint256 baseBefore) = _position();
        vm.prank(borrower);
        pool.liquidate(borrower, address(tbill), debtBefore / 2);
        (, uint256 debtAfter, uint256 baseAfter) = _position();

        // It was 3,980 of fee base for 24.90 of debt: 160 times.
        assertLe(baseBefore - baseAfter, debtBefore - debtAfter);
    }

    function testSelfLiquidationNoLongerBuysOutOfTheRedemptionFee() public {
        vm.prank(borrower);
        pool.draw(address(tbill), 7_960e6);
        uint256 afterDraw = pool.protocolFees();
        _repayThenThin();
        (, uint256 debtLeft,) = _position();
        uint256 beforeTheExit = vm.snapshotState();

        // The intended exit: close, paying what is owed.
        vm.prank(borrower);
        pool.closePosition(address(tbill));
        uint256 direct = pool.protocolFees() - afterDraw;

        // The route the issue found: be your own liquidator, halving until the position is healthy
        // or gone, then close whatever remains.
        vm.revertToState(beforeTheExit);
        while (pool.isLiquidatable(borrower, address(tbill))) {
            (, uint256 debt,) = _position();
            if (debt / 2 == 0) break;
            vm.prank(borrower);
            pool.liquidate(borrower, address(tbill), debt / 2);
        }
        (uint256 collateralLeft, uint256 debtStillOwed,) = _position();
        if (collateralLeft > 0 || debtStillOwed > 0) {
            vm.prank(borrower);
            pool.closePosition(address(tbill));
        }
        uint256 halving = pool.protocolFees() - afterDraw;

        // The direct exit collects the fee on the whole 7,960, less a unit of rounding per payment.
        assertApproxEqAbs(direct, _redemptionFee(7_960e6), 2);
        // It used to be 23.88 against 0. Now the most a liquidation can retire without a fee is the
        // principal inside the debt it settles, which is bounded by what was left after the repayment.
        assertGe(halving + _redemptionFee(debtLeft), direct, "self-liquidation escaped more than it settled");
    }

    // --------------------------------------------------------------------------------------
    // what the fee now is
    // --------------------------------------------------------------------------------------

    function testARepaymentTakesTheAmountPlusTheFeeOnThePrincipalItRetires() public {
        vm.prank(borrower);
        pool.draw(address(tbill), 5_000e6);
        (, uint256 debt, uint256 principal) = _position();
        uint256 amount = 2_000e6;
        uint256 retired = (principal * amount) / debt;
        uint256 fee = _redemptionFee(retired);
        uint256 balanceBefore = usdc.balanceOf(borrower);
        uint256 feesBefore = pool.protocolFees();

        vm.prank(borrower);
        pool.repay(address(tbill), amount);

        (, uint256 debtAfter, uint256 principalAfter) = _position();
        assertEq(debtAfter, debt - amount, "the debt falls by the amount, exactly as before");
        assertEq(principalAfter, principal - retired, "principal falls in proportion");
        assertEq(balanceBefore - usdc.balanceOf(borrower), amount + fee, "the amount, and the fee on top");
        assertEq(pool.protocolFees() - feesBefore, fee);
        assertEq(pool.totalDebt(), debtAfter, "the fee is paid, not added to the debt");
    }

    function testRepayingInFullPaysTheFeeThenAndLeavesNothingToSkipAtClose() public {
        vm.prank(borrower);
        pool.draw(address(tbill), 5_000e6);
        (, uint256 debt, uint256 principal) = _position();
        uint256 afterDraw = pool.protocolFees();

        vm.prank(borrower);
        pool.repay(address(tbill), debt);
        assertEq(pool.protocolFees() - afterDraw, _redemptionFee(principal), "paying the principal back pays its fee");
        (,, uint256 principalLeft) = _position();
        assertEq(principalLeft, 0);

        // Which is why the fee cannot be skipped by repaying before closing: there is nothing left.
        uint256 atClose = pool.protocolFees();
        vm.prank(borrower);
        pool.closePosition(address(tbill));
        assertEq(pool.protocolFees(), atClose);
    }

    function testTheFeeIsTheSameWhetherPrincipalGoesBackInPiecesOrAtClose() public {
        uint256 start = vm.snapshotState();
        vm.prank(borrower);
        pool.draw(address(tbill), 5_000e6);
        uint256 afterDraw = pool.protocolFees();
        vm.prank(borrower);
        pool.closePosition(address(tbill));
        uint256 atOnce = pool.protocolFees() - afterDraw;
        assertEq(atOnce, _redemptionFee(5_000e6), "closing straight away is exactly what it always was");

        vm.revertToState(start);
        vm.prank(borrower);
        pool.draw(address(tbill), 5_000e6);
        afterDraw = pool.protocolFees();
        vm.startPrank(borrower);
        pool.repay(address(tbill), 2_000e6);
        pool.repay(address(tbill), 1_000e6);
        pool.closePosition(address(tbill));
        vm.stopPrank();
        uint256 inPieces = pool.protocolFees() - afterDraw;

        // Each payment rounds its own fee down, so three payments can come in a unit short each,
        // never over.
        assertLe(inPieces, atOnce);
        assertApproxEqAbs(inPieces, atOnce, 3);
    }

    function testPrincipalNeverExceedsDebtThroughRepaymentsAndLiquidations() public {
        vm.prank(borrower);
        pool.draw(address(tbill), 7_960e6);
        _assertPrincipalWithinDebt();

        vm.prank(borrower);
        pool.repay(address(tbill), 7_000e6);
        _assertPrincipalWithinDebt();

        // 100 tBILL at $10 is worth 1,000 against 999.8 of debt, under the 90% threshold.
        pool.setPrice(address(tbill), 10e18);
        vm.prank(borrower);
        pool.liquidate(borrower, address(tbill), 300e6);
        _assertPrincipalWithinDebt();

        vm.prank(borrower);
        pool.repay(address(tbill), 100e6);
        _assertPrincipalWithinDebt();
    }

    function testAFullyRepaidPositionCanReleaseAllItsCollateral() public {
        vm.prank(borrower);
        pool.draw(address(tbill), 5_000e6);
        (, uint256 debt,) = _position();

        // The fee on every unit of principal was paid with the repayment, so a close would collect
        // nothing, and there is nothing to hold the last collateral back for.
        vm.startPrank(borrower);
        pool.repay(address(tbill), debt);
        pool.withdrawCollateral(address(tbill), 100e18);
        vm.stopPrank();

        (uint256 collateral, uint256 debtLeft, uint256 principal) = _position();
        assertEq(collateral, 0);
        assertEq(debtLeft, 0);
        assertEq(principal, 0);
        assertEq(tbill.balanceOf(borrower), 100e18);
    }

    // --------------------------------------------------------------------------------------
    // what an interface reads, and what the chain records
    // --------------------------------------------------------------------------------------

    function testTheQuoteIsExactlyWhatRepayTakes() public {
        vm.prank(borrower);
        pool.draw(address(tbill), 5_000e6);

        (uint256 debtRetired, uint256 fee) = pool.repaymentOwed(borrower, address(tbill), 2_000e6);
        assertEq(debtRetired, 2_000e6);
        uint256 balanceBefore = usdc.balanceOf(borrower);
        vm.prank(borrower);
        pool.repay(address(tbill), 2_000e6);
        assertEq(balanceBefore - usdc.balanceOf(borrower), debtRetired + fee);

        // With a floor, an amount that would leave dust is quoted as the whole debt and its fee:
        // what an interface has to approve for the cure to go through in one call.
        pool.setRiskLimits(0, 2_000e6, 0);
        (, uint256 debt, uint256 principal) = _position();
        (debtRetired, fee) = pool.repaymentOwed(borrower, address(tbill), debt - 1);
        assertEq(debtRetired, debt);
        assertEq(fee, _redemptionFee(principal));
        balanceBefore = usdc.balanceOf(borrower);
        vm.prank(borrower);
        pool.repay(address(tbill), debt - 1);
        assertEq(balanceBefore - usdc.balanceOf(borrower), debtRetired + fee);

        // And it refuses what repay refuses.
        vm.expectRevert(bytes("bad amount"));
        pool.repaymentOwed(borrower, address(tbill), 1);
    }

    function testARepaymentRecordsTheFeeItPaid() public {
        vm.prank(borrower);
        pool.draw(address(tbill), 5_000e6);
        (, uint256 debt, uint256 principal) = _position();
        uint256 retired = (principal * 2_000e6) / debt;

        // Repaid keeps its shape — the debt retired — so nothing reading it breaks; the fee is its
        // own record beside it.
        vm.expectEmit(true, true, false, true, address(pool));
        emit SafixPool.Repaid(borrower, address(tbill), 2_000e6);
        vm.expectEmit(true, true, false, true, address(pool));
        emit SafixPool.RedemptionFeePaid(borrower, address(tbill), retired, _redemptionFee(retired));
        vm.prank(borrower);
        pool.repay(address(tbill), 2_000e6);
    }
}
