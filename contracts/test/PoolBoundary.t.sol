// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice The boundary where a lone borrower's debt equals everything providers have left (#31).
///
/// Providers can only withdraw available liquidity, so their deposits never fall below the debt
/// outstanding — but they can land exactly on it. `liquidate` and `absorbBadDebt` used to require
/// deposits strictly above the debt, which refused them at that point even when the reserve would
/// have covered the shortfall, and left the debt counting against the caps with nothing able to
/// clear it. The requirement is now measured against what providers actually carry: the debt
/// cancelled, less whatever the reserve pays on their behalf.
contract PoolBoundaryTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal tbill;

    address internal providerOne = makeAddr("providerOne");
    address internal providerTwo = makeAddr("providerTwo");
    address internal borrower = makeAddr("borrower");
    address internal keeper = makeAddr("keeper");
    address internal sponsor = makeAddr("sponsor");

    /// @dev The reviewer's reproduction: a 5% origination fee, 190,476 drawn and the principal
    ///      repaid, which leaves 9,523.8 of pure fee as debt.
    uint256 internal constant DRAW = 190_476e6;
    uint256 internal constant COLLATERAL = 2_500e18;
    /// @dev Above what the collateral is worth at $1, so the position can be dust.
    uint256 internal constant FLOOR = 5_000e6;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);
        pool.setFees(500, 30);
        pool.setRiskLimits(0, FLOOR, 0);

        address[4] memory holders = [providerOne, providerTwo, borrower, sponsor];
        for (uint256 i = 0; i < holders.length; i++) {
            usdc.mint(holders[i], 1_000_000e6);
            vm.prank(holders[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
        tbill.mint(borrower, COLLATERAL);
        vm.prank(borrower);
        tbill.approve(address(pool), type(uint256).max);

        vm.prank(providerOne);
        pool.deposit(100_000e6);
        vm.prank(providerTwo);
        pool.deposit(100_000e6);
    }

    function _debt() internal view returns (uint256 debt) {
        (, debt,) = pool.positions(borrower, address(tbill));
    }

    function _assertSolvent() internal view {
        assertEq(
            usdc.balanceOf(address(pool)) + _debt(),
            pool.totalDeposits() + pool.protocolFees() + pool.reserve(),
            "pool is not solvent"
        );
    }

    /// @dev Draw, repay the principal so the fee alone is left as debt, then let both providers
    ///      take everything available. Deposits land exactly on the debt.
    function _landOnTheBoundary() internal returns (uint256 debt) {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), COLLATERAL);
        pool.draw(address(tbill), DRAW);
        pool.repay(address(tbill), DRAW);
        vm.stopPrank();
        debt = _debt();
        assertEq(debt, (DRAW * uint256(pool.originationFeeBps())) / 10_000, "setup: the debt is the fee alone");

        address[2] memory providers = [providerOne, providerTwo];
        for (uint256 i = 0; i < providers.length; i++) {
            uint256 available = pool.availableLiquidity();
            uint256 own = pool.compoundedDepositOf(providers[i]);
            vm.prank(providers[i]);
            pool.withdraw(own < available ? own : available);
        }
        assertEq(pool.totalDeposits(), debt, "setup: deposits land exactly on the debt");
        assertEq(pool.availableLiquidity(), 0, "setup: nothing left to withdraw");
    }

    // --------------------------------------------------------------------------------------
    // the reviewer's two refusals, which the reserve should have cleared
    // --------------------------------------------------------------------------------------

    function testDustAtTheBoundaryIsAbsorbedWhenTheReserveCoversIt() public {
        uint256 debt = _landOnTheBoundary();
        vm.prank(sponsor);
        pool.fundReserve(10_000e6);

        // 2,500 tBILL at $1 is worth 2,500: under the 5,000 floor, so this is dust nobody will
        // liquidate. It used to revert "pool too small", reserve or no reserve.
        pool.setPrice(address(tbill), 1e18);
        uint256 value = pool.collateralValueStable(address(tbill), COLLATERAL);
        assertLt(value, FLOOR);

        pool.absorbBadDebt(borrower, address(tbill));

        uint256 shortfall = debt - value;
        assertEq(_debt(), 0);
        assertEq(pool.badDebt(), 0, "the reserve covered it, so nothing was socialised");
        assertEq(pool.reserve(), 10_000e6 - shortfall);
        // Providers carry only what the collateral was worth, and they receive that collateral. Each
        // share is rounded down by the product-sum accounting, so the two together can fall a unit
        // or two short of the whole and never exceed it.
        assertEq(pool.totalDeposits(), debt - value);
        uint256 gains = pool.gainOf(providerOne, address(tbill)) + pool.gainOf(providerTwo, address(tbill));
        assertLe(gains, COLLATERAL, "providers were credited more collateral than the pool took");
        assertApproxEqAbs(gains, COLLATERAL, 2);
        // And the debt stops counting against the caps.
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.assetDebt(address(tbill)), 0);
        _assertSolvent();
    }

    function testALiquidationAtTheBoundaryGoesThroughWhenTheReserveCoversTheShortfall() public {
        uint256 debt = _landOnTheBoundary();
        vm.prank(sponsor);
        pool.fundReserve(10_000e6);

        // At $3 the collateral no longer covers the debt: after the keeper's share the pool receives
        // 2,487.5 tBILL, worth 7,462.5 against 9,523.8.
        pool.setPrice(address(tbill), 3e18);
        assertTrue(pool.isLiquidatable(borrower, address(tbill)));
        uint256 incentive = (COLLATERAL * pool.liquidationIncentiveBps()) / 10_000;
        uint256 received = pool.collateralValueStable(address(tbill), COLLATERAL - incentive);
        uint256 shortfall = debt - received;

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        assertEq(_debt(), 0);
        assertEq(pool.badDebt(), 0);
        assertEq(pool.reserve(), 10_000e6 - shortfall);
        assertEq(pool.totalDeposits(), debt - received);
        assertEq(pool.totalDebt(), 0);
        assertEq(tbill.balanceOf(keeper), incentive);
        _assertSolvent();
    }

    // --------------------------------------------------------------------------------------
    // the one refusal left, and why it is not a trap
    // --------------------------------------------------------------------------------------

    function testALiquidationThatWouldEmptyTheDepositsWaitsForOneMoreUnit() public {
        uint256 debt = _landOnTheBoundary();

        // At $4 the position is liquidatable but the collateral still covers the debt, so there is
        // no shortfall and nothing a reserve could pay. Cancelling it would take every last unit of
        // provider deposits, and the product-sum accounting cannot represent a pool emptied to
        // zero: P would reach zero, and every later deposit would compound to nothing.
        pool.setPrice(address(tbill), 4e18);
        assertTrue(pool.isLiquidatable(borrower, address(tbill)));

        vm.prank(keeper);
        vm.expectRevert(bytes("pool too small"));
        pool.liquidate(borrower, address(tbill), type(uint256).max);
        assertEq(_debt(), debt, "nothing moved");

        // It is not a trap: one unit of new deposits is enough.
        vm.prank(providerOne);
        pool.deposit(1);
        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);
        assertEq(_debt(), 0);
        assertEq(pool.totalDebt(), 0);
        _assertSolvent();
    }

    function testAShortfallAtTheBoundaryWaitsOnlyUntilSomethingCanCoverIt() public {
        uint256 debt = _landOnTheBoundary();
        assertEq(pool.reserve(), 0, "setup: no fee share, no reserve");

        // At $3 there is a shortfall and an empty reserve, so providers would carry the whole debt,
        // which is all of their deposits: refused, and nothing is booked.
        pool.setPrice(address(tbill), 3e18);
        vm.prank(keeper);
        vm.expectRevert(bytes("pool too small"));
        pool.liquidate(borrower, address(tbill), type(uint256).max);
        assertEq(pool.badDebt(), 0, "a refused liquidation books nothing");

        // The first unit of cover is enough, because the requirement is on what providers carry.
        vm.prank(sponsor);
        pool.fundReserve(1);
        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        uint256 incentive = (COLLATERAL * pool.liquidationIncentiveBps()) / 10_000;
        uint256 received = pool.collateralValueStable(address(tbill), COLLATERAL - incentive);
        assertEq(_debt(), 0);
        assertEq(pool.reserve(), 0);
        assertEq(pool.badDebt(), debt - received - 1, "the shortfall less the one unit the reserve paid");
        assertEq(pool.totalDeposits(), 1);
        _assertSolvent();
    }
}
