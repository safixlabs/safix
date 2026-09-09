// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {PartnershipDesk} from "../src/PartnershipDesk.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice The brake: who may pull it, who may release it, what it stops, and what it must never
///         stop. The central test drives every user-facing entry point through all eight
///         combinations of the pool's three pause bits.
contract EmergencyPauseTest is Test {
    SafixPool internal pool;
    PartnershipDesk internal desk;
    MockERC20 internal usdc;
    MockERC20 internal tbill;

    address internal owner = address(this);
    address internal guardian = makeAddr("guardian");
    address internal provider = makeAddr("provider");
    address internal borrower = makeAddr("borrower");
    address internal keeper = makeAddr("keeper");
    address internal outsider = makeAddr("outsider");
    address internal operator = makeAddr("operator");

    uint8 internal constant DRAWS = 1;
    uint8 internal constant DEPOSITS = 2;
    uint8 internal constant LIQUIDATIONS = 4;
    uint8 internal constant ALL = 7;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        desk = new PartnershipDesk(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);
        pool.setGuardian(guardian);
        desk.setGuardian(guardian);

        usdc.mint(provider, 1_000_000e6);
        usdc.mint(borrower, 1_000_000e6);
        usdc.mint(operator, 1_000_000e6);
        tbill.mint(borrower, 10_000e18);

        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        usdc.approve(address(desk), type(uint256).max);
        tbill.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.prank(operator);
        usdc.approve(address(desk), type(uint256).max);

        vm.prank(provider);
        pool.deposit(500_000e6);
    }

    // --------------------------------------------------------------------------------------
    // who may pull the brake, and who may release it
    // --------------------------------------------------------------------------------------

    function testGuardianCanPauseButNotUnpause() public {
        vm.prank(guardian);
        pool.pause(ALL);
        assertEq(pool.pausedActions(), ALL);

        // The whole point of the split: the guardian's key cannot restart the protocol.
        vm.prank(guardian);
        vm.expectRevert(bytes("not owner"));
        pool.unpause(ALL);
        assertEq(pool.pausedActions(), ALL);

        pool.unpause(ALL);
        assertEq(pool.pausedActions(), 0);
    }

    function testOwnerCanAlsoPause() public {
        pool.pause(DRAWS);
        assertTrue(pool.isPaused(DRAWS));
    }

    function testOutsiderCanDoNeither() public {
        vm.startPrank(outsider);
        vm.expectRevert(bytes("not guardian"));
        pool.pause(DRAWS);
        vm.expectRevert(bytes("not owner"));
        pool.unpause(DRAWS);
        vm.expectRevert(bytes("not owner"));
        pool.setGuardian(outsider);
        vm.stopPrank();
    }

    function testGuardianIsSeparateFromOwner() public view {
        assertEq(pool.guardian(), guardian);
        assertEq(pool.owner(), owner);
        assertTrue(pool.guardian() != pool.owner());
    }

    function testGuardianCanBeReplacedAndRemoved() public {
        address next = makeAddr("nextGuardian");
        pool.setGuardian(next);
        assertEq(pool.guardian(), next);

        vm.prank(guardian);
        vm.expectRevert(bytes("not guardian"));
        pool.pause(DRAWS);

        vm.prank(next);
        pool.pause(DRAWS);

        // Removing the guardian leaves the owner able to pause.
        pool.setGuardian(address(0));
        pool.pause(DEPOSITS);
        assertEq(pool.pausedActions(), DRAWS | DEPOSITS);
    }

    // --------------------------------------------------------------------------------------
    // acceptance: one transaction, one block
    // --------------------------------------------------------------------------------------

    function testOneGuardianTransactionStopsAllNewRisk() public {
        uint256 blockBefore = block.number;

        vm.prank(guardian);
        pool.pause(ALL);

        assertEq(block.number, blockBefore, "took more than one block");
        assertTrue(pool.isPaused(DRAWS));
        assertTrue(pool.isPaused(DEPOSITS));
        assertTrue(pool.isPaused(LIQUIDATIONS));

        vm.prank(provider);
        vm.expectRevert(bytes("deposits paused"));
        pool.deposit(1e6);

        vm.prank(borrower);
        vm.expectRevert(bytes("draws paused"));
        pool.draw(address(tbill), 1e6);

        vm.prank(keeper);
        vm.expectRevert(bytes("liquidations paused"));
        pool.liquidate(borrower, address(tbill), 1e6);
    }

    // --------------------------------------------------------------------------------------
    // every entry point, in every pause state
    // --------------------------------------------------------------------------------------

    /// @dev Walks all eight combinations of the three bits. For each, every user-facing entry point
    ///      is attempted and checked against what that state should allow. An entry point that is
    ///      not pausable must succeed in all eight.
    function testEveryEntryPointInEveryPauseState() public {
        for (uint8 mask = 0; mask <= ALL; mask++) {
            uint256 snapshot = vm.snapshotState();

            if (mask != 0) {
                vm.prank(guardian);
                pool.pause(mask);
            }
            assertEq(pool.pausedActions(), mask);

            bool drawsOff = (mask & DRAWS) != 0;
            bool depositsOff = (mask & DEPOSITS) != 0;
            bool liquidationsOff = (mask & LIQUIDATIONS) != 0;

            // --- deposit: pausable
            vm.prank(provider);
            if (depositsOff) vm.expectRevert(bytes("deposits paused"));
            pool.deposit(1_000e6);

            // --- lockCollateral: never pausable, adding collateral cannot worsen a position
            vm.prank(borrower);
            pool.lockCollateral(address(tbill), 100e18);

            // --- draw: pausable
            vm.prank(borrower);
            if (drawsOff) vm.expectRevert(bytes("draws paused"));
            pool.draw(address(tbill), 1_000e6);

            // Give the borrower a position to exit from, whatever the draw above did.
            if (drawsOff) {
                pool.unpause(DRAWS);
                vm.prank(borrower);
                pool.draw(address(tbill), 1_000e6);
                vm.prank(guardian);
                pool.pause(DRAWS);
            }

            // --- repay: never pausable
            vm.prank(borrower);
            pool.repay(address(tbill), 100e6);

            // --- withdrawCollateral against a live loan: never pausable, still LTV-checked
            vm.prank(borrower);
            pool.withdrawCollateral(address(tbill), 10e18);

            // --- closePosition: never pausable, collateral comes back
            vm.prank(borrower);
            pool.closePosition(address(tbill));

            // --- liquidate: pausable. Build a position and put it underwater.
            vm.startPrank(borrower);
            pool.lockCollateral(address(tbill), 100e18);
            if (drawsOff) {
                vm.stopPrank();
                pool.unpause(DRAWS);
                vm.prank(borrower);
                pool.draw(address(tbill), 5_000e6);
                vm.prank(guardian);
                pool.pause(DRAWS);
            } else {
                pool.draw(address(tbill), 5_000e6);
                vm.stopPrank();
            }
            pool.setPrice(address(tbill), 55e18);

            vm.prank(keeper);
            if (liquidationsOff) vm.expectRevert(bytes("liquidations paused"));
            pool.liquidate(borrower, address(tbill), type(uint256).max);
            pool.setPrice(address(tbill), 100e18);

            // --- claimGains: never pausable
            address[] memory assets = new address[](1);
            assets[0] = address(tbill);
            vm.prank(provider);
            pool.claimGains(assets);

            // --- withdraw liquidity: never pausable, a provider is never trapped
            vm.prank(provider);
            pool.withdraw(1_000e6);

            vm.revertToState(snapshot);
        }
    }

    // --------------------------------------------------------------------------------------
    // the bits are independent
    // --------------------------------------------------------------------------------------

    function testPausingDrawsLeavesDepositsAndLiquidationsAlone() public {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.draw(address(tbill), 5_000e6);
        vm.stopPrank();
        pool.setPrice(address(tbill), 55e18);

        vm.prank(guardian);
        pool.pause(DRAWS);

        vm.prank(provider);
        pool.deposit(1_000e6);

        vm.prank(keeper);
        pool.liquidate(borrower, address(tbill), type(uint256).max);

        vm.prank(borrower);
        vm.expectRevert(bytes("draws paused"));
        pool.draw(address(tbill), 1e6);
    }

    function testUnpausingOneBitLeavesTheOthersPaused() public {
        vm.prank(guardian);
        pool.pause(ALL);

        pool.unpause(DEPOSITS);
        assertEq(pool.pausedActions(), DRAWS | LIQUIDATIONS);

        vm.prank(provider);
        pool.deposit(1_000e6);

        vm.prank(borrower);
        vm.expectRevert(bytes("draws paused"));
        pool.draw(address(tbill), 1e6);
    }

    function testPausingIsIdempotentAndAdditive() public {
        vm.startPrank(guardian);
        pool.pause(DRAWS);
        pool.pause(DRAWS);
        assertEq(pool.pausedActions(), DRAWS);
        pool.pause(LIQUIDATIONS);
        assertEq(pool.pausedActions(), DRAWS | LIQUIDATIONS);
        vm.stopPrank();

        pool.unpause(ALL);
        assertEq(pool.pausedActions(), 0);
    }

    function testEmptyPauseIsRejected() public {
        vm.prank(guardian);
        vm.expectRevert(bytes("nothing to pause"));
        pool.pause(0);

        vm.expectRevert(bytes("nothing to unpause"));
        pool.unpause(0);
    }

    // --------------------------------------------------------------------------------------
    // events, so an incident log has something to point at
    // --------------------------------------------------------------------------------------

    event Paused(uint8 actions, uint8 pausedAfter, address indexed by);
    event Unpaused(uint8 actions, uint8 pausedAfter, address indexed by);
    event GuardianSet(address indexed guardian);

    function testPauseAndUnpauseEmitWhatHappenedAndWhoDidIt() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit Paused(DRAWS, DRAWS, guardian);
        vm.prank(guardian);
        pool.pause(DRAWS);

        vm.expectEmit(true, false, false, true, address(pool));
        emit Paused(LIQUIDATIONS, DRAWS | LIQUIDATIONS, guardian);
        vm.prank(guardian);
        pool.pause(LIQUIDATIONS);

        vm.expectEmit(true, false, false, true, address(pool));
        emit Unpaused(DRAWS, LIQUIDATIONS, owner);
        pool.unpause(DRAWS);
    }

    function testSettingTheGuardianIsAnnounced() public {
        address next = makeAddr("nextGuardian");
        vm.expectEmit(true, false, false, false, address(pool));
        emit GuardianSet(next);
        pool.setGuardian(next);
    }

    // --------------------------------------------------------------------------------------
    // the partnership desk
    // --------------------------------------------------------------------------------------

    function _openPartnership() internal returns (uint256 id) {
        id = desk.createPartnership(operator, 4000, 100_000e6, uint64(block.timestamp + 30 days), uint64(block.timestamp + 200 days));
    }

    function testFundingPausesAndClaimsDoNot() public {
        uint256 id = _openPartnership();
        vm.prank(borrower);
        desk.fund(id, 10_000e6);

        vm.prank(guardian);
        desk.pause(desk.PAUSE_FUNDING());

        vm.prank(borrower);
        vm.expectRevert(bytes("funding paused"));
        desk.fund(id, 1_000e6);

        // The cycle still completes: capital out, return in, settle, and both sides collect.
        desk.activate(id);
        vm.prank(operator);
        desk.reportReturn(id, 12_000e6);
        desk.settle(id);

        vm.prank(borrower);
        desk.claim(id);
        vm.prank(operator);
        desk.claimOperator(id);

        assertTrue(desk.claimed(id, borrower));
    }

    function testCancelledPartnershipStillRefundsWhilePaused() public {
        uint256 id = _openPartnership();
        vm.prank(borrower);
        desk.fund(id, 10_000e6);

        vm.prank(guardian);
        desk.pause(desk.PAUSE_ALL());
        desk.cancel(id);

        uint256 before = usdc.balanceOf(borrower);
        vm.prank(borrower);
        desk.claim(id);
        assertEq(usdc.balanceOf(borrower) - before, 10_000e6);
    }

    function testDeskGuardianCannotUnpauseEither() public {
        // Read the constant before any expectRevert, or the view call is what gets caught.
        uint8 funding = desk.PAUSE_FUNDING();
        vm.prank(guardian);
        desk.pause(funding);

        vm.prank(guardian);
        vm.expectRevert(bytes("not owner"));
        desk.unpause(funding);

        desk.unpause(funding);
        assertEq(desk.pausedActions(), 0);

        uint256 id = _openPartnership();
        vm.prank(borrower);
        desk.fund(id, 1_000e6);
    }

    function testDeskOutsiderCanDoNeither() public {
        uint8 funding = desk.PAUSE_FUNDING();
        vm.startPrank(outsider);
        vm.expectRevert(bytes("not guardian"));
        desk.pause(funding);
        vm.expectRevert(bytes("not owner"));
        desk.unpause(funding);
        vm.stopPrank();
    }
}
