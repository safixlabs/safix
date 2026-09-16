// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice The position floor and the repayment that cures a position (#30).
///
/// `minPositionDebt` keeps a position from sitting below the value of the gas it would take to
/// liquidate it. `liquidate` already honours that by rounding a dust-leaving offset up to the whole
/// position. `repay` used to refuse the same case outright, which refused the one repayment that
/// could cure an unhealthy position and stranded any position left under a floor raised after it
/// opened. It now mirrors `liquidate`: a repayment that would leave dust takes the whole debt,
/// provided the borrower has approved and holds it, and the floor's purpose is intact — a position
/// still ends at zero or at the floor and above, never in between.
contract RepayFloorTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal tbill;

    address internal provider = makeAddr("provider");
    address internal borrower = makeAddr("borrower");
    address internal outsider = makeAddr("outsider");

    /// @dev The reviewer's measured setup: 100 tBILL at $100, 5500 max LTV, 7000 threshold, a
    ///      5,000 draw, the price falling to $60, and a 4,500 floor.
    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant DRAW = 5_000e6;
    uint256 internal constant FLOOR = 4_500e6;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 5500, 7000, 100e18);

        usdc.mint(provider, 1_000_000e6);
        usdc.mint(borrower, 100_000e6);
        tbill.mint(borrower, 1_000e18);

        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        tbill.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.prank(provider);
        pool.deposit(1_000_000e6);
    }

    /// @dev Opens the reviewer's position and drops the price through the threshold. Returns the
    ///      debt, which carries the origination fee: 5,025 for a 5,000 draw at the default 50 bps.
    function _openUnhealthyPosition() internal returns (uint256 debt) {
        pool.setRiskLimits(0, FLOOR, 0);
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), COLLATERAL);
        pool.draw(address(tbill), DRAW);
        vm.stopPrank();
        pool.setPrice(address(tbill), 60e18);

        (, debt,) = pool.positions(borrower, address(tbill));
        uint256 fee = (DRAW * uint256(pool.originationFeeBps())) / 10_000;
        assertEq(debt, DRAW + fee, "setup: debt is the draw plus its fee");
        assertTrue(pool.isLiquidatable(borrower, address(tbill)), "setup: the price drop made it unhealthy");
    }

    /// @dev The threshold value of the position's collateral: the debt at which it is exactly
    ///      healthy. $6,000 of collateral at a 70% threshold is 4,200.
    function _healthyDebt() internal view returns (uint256) {
        uint256 value = pool.collateralValueStable(address(tbill), COLLATERAL);
        (,, uint16 threshold,,,) = pool.assetConfig(address(tbill));
        return (value * threshold) / 10_000;
    }

    function _principal() internal view returns (uint256 principal) {
        (,, principal) = pool.positions(borrower, address(tbill));
    }

    /// @dev The redemption fee on principal paid back (#33): charged whenever principal goes back,
    ///      so a repayment costs the amount plus the fee on the principal it retires.
    function _redemptionFee(uint256 principal) internal view returns (uint256) {
        return (principal * pool.redemptionFeeBps()) / 10_000;
    }

    // --------------------------------------------------------------------------------------
    // the measured case
    // --------------------------------------------------------------------------------------

    function testTheLargestPartialTheFloorAllowsLeavesThePositionLiquidatable() public {
        uint256 debt = _openUnhealthyPosition();
        uint256 principal = _principal();
        uint256 balanceBefore = usdc.balanceOf(borrower);

        // Repaying down to exactly the floor is allowed, and takes what was asked plus the
        // redemption fee on the principal it retires.
        vm.prank(borrower);
        pool.repay(address(tbill), debt - FLOOR);

        (, uint256 remaining,) = pool.positions(borrower, address(tbill));
        assertEq(remaining, FLOOR);
        assertEq(
            balanceBefore - usdc.balanceOf(borrower),
            (debt - FLOOR) + _redemptionFee((principal * (debt - FLOOR)) / debt)
        );
        // And it does not cure: the floor sits above the healthy debt. This is why the repayment
        // below has to be possible at all.
        assertGt(FLOOR, _healthyDebt());
        assertTrue(pool.isLiquidatable(borrower, address(tbill)));
    }

    function testTheRepaymentThatCuresAnUnhealthyPositionIsNotRefused() public {
        uint256 debt = _openUnhealthyPosition();
        uint256 principal = _principal();
        uint256 balanceBefore = usdc.balanceOf(borrower);

        // 825 would leave 4,200, exactly healthy, and under the 4,500 floor. It used to revert
        // "position too small". It now takes the whole debt, as a liquidation would.
        uint256 cure = debt - _healthyDebt();
        vm.prank(borrower);
        pool.repay(address(tbill), cure);

        (uint256 collateral, uint256 remaining,) = pool.positions(borrower, address(tbill));
        assertEq(remaining, 0, "the position ends at zero, not in the dust band");
        assertEq(collateral, COLLATERAL, "collateral stays locked until the borrower closes");
        assertFalse(pool.isLiquidatable(borrower, address(tbill)));
        assertEq(
            balanceBefore - usdc.balanceOf(borrower),
            debt + _redemptionFee(principal),
            "the whole debt was taken, with the fee on the whole principal"
        );
        assertEq(pool.assetDebt(address(tbill)), 0);
        assertEq(pool.totalDebt(), 0);
    }

    function testAnEscalatedRepaymentReportsWhatWasActuallyTaken() public {
        uint256 debt = _openUnhealthyPosition();
        // Anything reading the history — the indexer's fold, the app's activity list — takes the
        // amount from this event. It has to be the amount that moved, not the amount requested.
        uint256 cure = debt - _healthyDebt();
        vm.expectEmit(true, true, false, true, address(pool));
        emit SafixPool.Repaid(borrower, address(tbill), debt);
        vm.prank(borrower);
        pool.repay(address(tbill), cure);
    }

    // --------------------------------------------------------------------------------------
    // what escalation needs
    // --------------------------------------------------------------------------------------

    function testEscalationNeedsAnAllowanceForTheWholeDebt() public {
        uint256 debt = _openUnhealthyPosition();
        uint256 cure = debt - _healthyDebt();
        uint256 owed = debt + _redemptionFee(_principal());

        // One unit short of the whole debt and its fee: the refusal stands, and nothing moves.
        vm.prank(borrower);
        usdc.approve(address(pool), owed - 1);
        vm.prank(borrower);
        vm.expectRevert(bytes("position too small"));
        pool.repay(address(tbill), cure);
        (, uint256 unchanged,) = pool.positions(borrower, address(tbill));
        assertEq(unchanged, debt);

        // Exactly the whole debt and its fee: it escalates.
        vm.prank(borrower);
        usdc.approve(address(pool), owed);
        vm.prank(borrower);
        pool.repay(address(tbill), cure);
        (, uint256 remaining,) = pool.positions(borrower, address(tbill));
        assertEq(remaining, 0);
    }

    function testEscalationNeedsABalanceForTheWholeDebt() public {
        uint256 debt = _openUnhealthyPosition();
        uint256 cure = debt - _healthyDebt();
        uint256 owed = debt + _redemptionFee(_principal());

        // One unit short of the whole debt and its fee.
        uint256 balance = usdc.balanceOf(borrower);
        vm.prank(borrower);
        usdc.transfer(outsider, balance - (owed - 1));
        vm.prank(borrower);
        vm.expectRevert(bytes("position too small"));
        pool.repay(address(tbill), cure);

        // Exactly the whole debt and its fee.
        usdc.mint(borrower, 1);
        vm.prank(borrower);
        pool.repay(address(tbill), cure);
        (, uint256 remaining,) = pool.positions(borrower, address(tbill));
        assertEq(remaining, 0);
        assertEq(usdc.balanceOf(borrower), 0);
    }

    // --------------------------------------------------------------------------------------
    // the second half: a floor raised after the position opened
    // --------------------------------------------------------------------------------------

    function testAPositionLeftUnderARaisedFloorCanStillBeRepaid() public {
        pool.setRiskLimits(0, 500e6, 0);
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), COLLATERAL);
        pool.draw(address(tbill), 1_000e6);
        vm.stopPrank();
        (, uint256 debt, uint256 principal) = pool.positions(borrower, address(tbill));

        // Governance raises the floor above a position that was never near liquidation. Every
        // partial repayment now leaves it under the floor.
        pool.setRiskLimits(0, 2_000e6, 0);
        assertFalse(pool.isLiquidatable(borrower, address(tbill)));

        uint256 balanceBefore = usdc.balanceOf(borrower);
        vm.prank(borrower);
        pool.repay(address(tbill), 100e6);

        (, uint256 remaining,) = pool.positions(borrower, address(tbill));
        assertEq(remaining, 0);
        assertEq(balanceBefore - usdc.balanceOf(borrower), debt + _redemptionFee(principal));
    }

    // --------------------------------------------------------------------------------------
    // what does not change
    // --------------------------------------------------------------------------------------

    function testWithNoFloorAPartialRepaymentIsNeverEscalated() public {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), COLLATERAL);
        pool.draw(address(tbill), DRAW);
        (, uint256 debt, uint256 principal) = pool.positions(borrower, address(tbill));

        uint256 balanceBefore = usdc.balanceOf(borrower);
        pool.repay(address(tbill), debt - 1);
        vm.stopPrank();

        (, uint256 remaining,) = pool.positions(borrower, address(tbill));
        assertEq(remaining, 1, "one unit left, exactly as asked");
        assertEq(balanceBefore - usdc.balanceOf(borrower), (debt - 1) + _redemptionFee((principal * (debt - 1)) / debt));
    }

    function testRepayingMoreThanTheDebtIsStillRefused() public {
        uint256 debt = _openUnhealthyPosition();
        vm.prank(borrower);
        vm.expectRevert(bytes("bad amount"));
        pool.repay(address(tbill), debt + 1);
    }
}
