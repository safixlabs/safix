// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice What happens when a price gaps through the liquidation threshold and the collateral is
///         worth less than the debt it was securing.
///
/// The rule these all check: the pool stays solvent, and the loss lands somewhere with a name. The
/// reserve absorbs it first; whatever the reserve cannot cover is socialised across providers and
/// recorded in `badDebt` rather than quietly diluting them.
contract BadDebtTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal tbill;

    address internal provider = makeAddr("provider");
    address internal providerTwo = makeAddr("providerTwo");
    address internal borrower = makeAddr("borrower");
    address internal keeper = makeAddr("keeper");
    address internal sponsor = makeAddr("sponsor");
    address internal treasury = makeAddr("treasury");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);

        usdc.mint(provider, 1_000_000e6);
        usdc.mint(providerTwo, 1_000_000e6);
        usdc.mint(borrower, 1_000_000e6);
        usdc.mint(sponsor, 1_000_000e6);
        tbill.mint(borrower, 10_000e18);

        for (uint256 i = 0; i < 4; i++) {
            address who = [provider, providerTwo, borrower, sponsor][i];
            vm.prank(who);
            usdc.approve(address(pool), type(uint256).max);
        }
        vm.prank(borrower);
        tbill.approve(address(pool), type(uint256).max);

        vm.prank(provider);
        pool.deposit(100_000e6);
    }

    /// @dev Every unit of stable is claimed by exactly one of providers, fees, or the reserve.
    function _assertSolvent() internal view {
        uint256 debt = _debt();
        assertEq(
            usdc.balanceOf(address(pool)) + debt,
            pool.totalDeposits() + pool.protocolFees() + pool.reserve(),
            "pool is not solvent"
        );
    }

    function _debt() internal view returns (uint256) {
        (, uint256 debt,) = pool.positions(borrower, address(tbill));
        return debt;
    }

    /// @dev Opens a position that a price gap can put underwater, and returns its debt.
    function _openPosition() internal returns (uint256 debt) {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.draw(address(tbill), 7_960e6);
        vm.stopPrank();
        (, debt,) = pool.positions(borrower, address(tbill));
    }

    // --------------------------------------------------------------------------------------
    // funding the reserve
    // --------------------------------------------------------------------------------------

    function testOriginationFeeSplitsBetweenReserveAndProtocolFees() public {
        pool.setReserveFeeShare(2_500); // a quarter to the reserve

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.draw(address(tbill), 7_960e6);
        vm.stopPrank();

        uint256 fee = (7_960e6 * 50) / 10_000; // 39.8
        assertEq(pool.reserve(), fee / 4);
        assertEq(pool.protocolFees(), fee - fee / 4);
        _assertSolvent();
    }

    function testReserveCanBeFundedFromOutsideTheFeeStream() public {
        vm.prank(sponsor);
        pool.fundReserve(5_000e6);
        assertEq(pool.reserve(), 5_000e6);
        _assertSolvent();
    }

    function testReserveIsNotLendableOrWithdrawableLiquidity() public {
        uint256 before = pool.availableLiquidity();
        vm.prank(sponsor);
        pool.fundReserve(5_000e6);

        // The balance went up but the lendable pool did not: the reserve is nobody's to draw.
        assertEq(pool.availableLiquidity(), before);
        assertEq(usdc.balanceOf(address(pool)), before + 5_000e6);
    }

    function testOwnerCanTakeBackTheReserveButNoFurther() public {
        vm.prank(sponsor);
        pool.fundReserve(5_000e6);

        vm.expectRevert(bytes("bad amount"));
        pool.withdrawReserve(treasury, 5_000e6 + 1);

        pool.withdrawReserve(treasury, 5_000e6);
        assertEq(usdc.balanceOf(treasury), 5_000e6);
        assertEq(pool.reserve(), 0);
        _assertSolvent();
    }

    function testReserveShareIsCappedAndOutsidersReachNeitherKnob() public {
        vm.expectRevert(bytes("share too high"));
        pool.setReserveFeeShare(5_001);

        vm.startPrank(outsider);
        vm.expectRevert(bytes("not timelock"));
        pool.setReserveFeeShare(100);
        // Taking money out of the reserve waits for the timelock too, once one is wired; the delay
        // itself is tested in Timelock.t.sol.
        vm.expectRevert(bytes("not timelock"));
        pool.withdrawReserve(outsider, 1);
        vm.stopPrank();
    }

    function testPullingTheReserveBeforeAGapDownMovesTheLossOntoProviders() public {
        vm.prank(sponsor);
        pool.fundReserve(10_000e6);
        uint256 debt = _openPosition();
        uint256 depositsBefore = pool.totalDeposits();

        // 100 tBILL gaps to 70. Seized 100, incentive 0.5, so the pool receives 99.5 at 70 = 6,965
        // against 7,999.8 of debt: a 1,034.8 shortfall.
        uint256 received = 6_965e6;
        uint256 shortfall = debt - received;
        uint256 beforeTheGap = vm.snapshotState();

        // With the reserve in place, it takes the shortfall.
        pool.setPrice(address(tbill), 70e18);
        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);
        assertEq(pool.badDebt(), 0);
        assertEq(pool.reserve(), 10_000e6 - shortfall);
        assertEq(depositsBefore - pool.totalDeposits(), received);
        _assertSolvent();

        // Pulled in the block before, the identical liquidation lands on providers instead. This is
        // what withdrawReserve could do with no notice, and why it now waits for the timelock.
        vm.revertToState(beforeTheGap);
        pool.withdrawReserve(treasury, 10_000e6);
        pool.setPrice(address(tbill), 70e18);
        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);
        assertEq(pool.badDebt(), shortfall);
        assertEq(pool.reserve(), 0);
        assertEq(depositsBefore - pool.totalDeposits(), debt);
        _assertSolvent();
    }

    function testCollectingProtocolFeesLeavesTheReserveAlone() public {
        pool.setReserveFeeShare(5_000);
        _openPosition();

        uint256 reserveBefore = pool.reserve();
        assertGt(reserveBefore, 0);
        pool.collectProtocolFees(treasury);

        assertEq(pool.protocolFees(), 0);
        assertEq(pool.reserve(), reserveBefore, "fee collection reached into the reserve");
        _assertSolvent();
    }

    // --------------------------------------------------------------------------------------
    // the gap-down itself
    // --------------------------------------------------------------------------------------

    function testGapDownWithNoReserveSocialisesAndRecordsTheLoss() public {
        uint256 debt = _openPosition();
        uint256 depositsBefore = pool.totalDeposits();

        // The price gaps to half, straight through the threshold. 100 tBILL is now worth 5,000
        // against 8,040 of debt.
        pool.setPrice(address(tbill), 50e18);

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        // seized 100, incentive 0.5, so the pool receives 99.5 tBILL at 50 = 4,975.
        uint256 received = 4_975e6;
        uint256 shortfall = debt - received;

        assertEq(pool.badDebt(), shortfall, "the loss was not recorded");
        assertEq(pool.reserve(), 0);
        // With no reserve, providers carry the whole offset, which is the old behaviour — but now
        // the part of it that is a genuine loss is named.
        assertEq(depositsBefore - pool.totalDeposits(), debt);
        assertEq(_debt(), 0);
        _assertSolvent();
    }

    function testReserveAbsorbsTheShortfallAndProvidersKeepTheDifference() public {
        vm.prank(sponsor);
        pool.fundReserve(10_000e6);

        uint256 debt = _openPosition();
        uint256 depositsBefore = pool.totalDeposits();
        pool.setPrice(address(tbill), 50e18);

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        uint256 received = 4_975e6;
        uint256 shortfall = debt - received;

        // Nothing was socialised: the reserve covered all of it.
        assertEq(pool.badDebt(), 0, "loss was socialised despite a funded reserve");
        assertEq(pool.reserve(), 10_000e6 - shortfall);
        // Providers lost only what the collateral was actually worth, not the whole debt.
        assertEq(depositsBefore - pool.totalDeposits(), received);
        _assertSolvent();
    }

    function testReserveDepletesAndTheRemainderIsSocialised() public {
        // Deliberately smaller than the coming shortfall.
        vm.prank(sponsor);
        pool.fundReserve(1_000e6);

        uint256 debt = _openPosition();
        uint256 depositsBefore = pool.totalDeposits();
        pool.setPrice(address(tbill), 50e18);

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        uint256 received = 4_975e6;
        uint256 shortfall = debt - received;

        assertEq(pool.reserve(), 0, "reserve should be spent to the last unit");
        assertEq(pool.badDebt(), shortfall - 1_000e6, "socialised remainder is wrong");
        // Providers carry the offset less what the reserve paid on their behalf.
        assertEq(depositsBefore - pool.totalDeposits(), debt - 1_000e6);
        _assertSolvent();
    }

    function testBadDebtEventCarriesTheSplit() public {
        vm.prank(sponsor);
        pool.fundReserve(1_000e6);
        uint256 debt = _openPosition();
        pool.setPrice(address(tbill), 50e18);

        uint256 shortfall = debt - 4_975e6;
        vm.expectEmit(true, true, false, true, address(pool));
        emit BadDebtRealised(borrower, address(tbill), shortfall, 1_000e6, shortfall - 1_000e6);
        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);
    }

    event BadDebtRealised(
        address indexed borrower,
        address indexed asset,
        uint256 shortfall,
        uint256 fromReserve,
        uint256 socialised
    );

    function testAHealthyLiquidationRecordsNoBadDebt() public {
        _openPosition();
        // Just past the threshold, where the collateral still covers the debt.
        pool.setPrice(address(tbill), 88e18);
        assertTrue(pool.isLiquidatable(borrower, address(tbill)));

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        assertEq(pool.badDebt(), 0, "a covered liquidation should not register bad debt");
        _assertSolvent();
    }

    function testProvidersShareTheSocialisedLossInProportion() public {
        vm.prank(providerTwo);
        pool.deposit(100_000e6); // equal halves of the pool

        _openPosition();
        pool.setPrice(address(tbill), 50e18);
        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        // The two providers are equal, so their compounded deposits stay equal after the loss.
        assertApproxEqAbs(
            pool.compoundedDepositOf(provider), pool.compoundedDepositOf(providerTwo), 2, "loss was not shared evenly"
        );
        assertGt(pool.badDebt(), 0);
        _assertSolvent();
    }

    // --------------------------------------------------------------------------------------
    // underwater dust
    // --------------------------------------------------------------------------------------

    function testUnderwaterDustCanBeAbsorbedWhenNobodyWouldLiquidateIt() public {
        pool.setRiskLimits(0, 1_000e6, 0);
        uint256 debt = _openPosition();

        // The collateral collapses to near nothing: 100 tBILL at 1 is worth 100, far below the
        // 1,000 dust threshold, so a keeper's 0.5% share is not worth the transaction.
        pool.setPrice(address(tbill), 1e18);
        assertTrue(pool.isLiquidatable(borrower, address(tbill)));

        uint256 depositsBefore = pool.totalDeposits();
        pool.absorbBadDebt(borrower, address(tbill));

        (uint256 collateral, uint256 remaining,) = pool.positions(borrower, address(tbill));
        assertEq(collateral, 0);
        assertEq(remaining, 0);
        assertEq(pool.badDebt(), debt - 100e6, "the write-off was not booked");
        assertEq(depositsBefore - pool.totalDeposits(), debt);
        assertEq(pool.assetDebt(address(tbill)), 0);
        assertEq(pool.assetCollateral(address(tbill)), 0);
        _assertSolvent();
    }

    function testDustWriteOffSendsTheCollateralToProviders() public {
        pool.setRiskLimits(0, 1_000e6, 0);
        _openPosition();
        pool.setPrice(address(tbill), 1e18);
        pool.absorbBadDebt(borrower, address(tbill));

        // Worth little, but it is the providers' little: no keeper incentive is carved out.
        assertEq(pool.gainOf(provider, address(tbill)), 100e18);
        address[] memory assets = new address[](1);
        assets[0] = address(tbill);
        vm.prank(provider);
        pool.claimGains(assets);
        assertEq(tbill.balanceOf(provider), 100e18);
    }

    function testDustWriteOffRefusesAHealthyOrNonDustPosition() public {
        pool.setRiskLimits(0, 1_000e6, 0);
        _openPosition();

        // Healthy.
        vm.expectRevert(bytes("healthy"));
        pool.absorbBadDebt(borrower, address(tbill));

        // Liquidatable, but the collateral is worth far more than the dust threshold, so an
        // ordinary liquidation is what should happen.
        pool.setPrice(address(tbill), 50e18);
        assertTrue(pool.isLiquidatable(borrower, address(tbill)));
        vm.expectRevert(bytes("not dust"));
        pool.absorbBadDebt(borrower, address(tbill));
    }

    function testDustWriteOffNeedsAThresholdAndIsOwnerOnly() public {
        _openPosition();
        pool.setPrice(address(tbill), 1e18);

        // Without a minimum position size there is no definition of dust to appeal to.
        vm.expectRevert(bytes("no dust threshold"));
        pool.absorbBadDebt(borrower, address(tbill));

        pool.setRiskLimits(0, 1_000e6, 0);
        vm.prank(outsider);
        vm.expectRevert(bytes("not owner"));
        pool.absorbBadDebt(borrower, address(tbill));
    }

    function testReserveCoversADustWriteOffToo() public {
        pool.setRiskLimits(0, 1_000e6, 0);
        vm.prank(sponsor);
        pool.fundReserve(20_000e6);

        uint256 debt = _openPosition();
        pool.setPrice(address(tbill), 1e18);

        uint256 depositsBefore = pool.totalDeposits();
        pool.absorbBadDebt(borrower, address(tbill));

        assertEq(pool.badDebt(), 0, "reserve should have covered the whole write-off");
        assertEq(pool.reserve(), 20_000e6 - (debt - 100e6));
        assertEq(depositsBefore - pool.totalDeposits(), 100e6);
        _assertSolvent();
    }
}
