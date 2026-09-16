// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixTimelock} from "../src/SafixTimelock.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {PartnershipDesk} from "../src/PartnershipDesk.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice The delay on risk parameters, and the line between what waits and what does not.
///
/// A timelock does not make a decision better. What it buys is a window: a change is visible
/// onchain before it binds anyone, so a lender who disagrees with a new LTV can leave first. These
/// tests hold that window open, and hold the brake outside it.
contract TimelockTest is Test {
    SafixTimelock internal timelock;
    SafixPool internal pool;
    PartnershipDesk internal desk;
    MockERC20 internal usdc;
    MockERC20 internal tbill;

    address internal multisig = makeAddr("multisig");
    address internal guardian = makeAddr("guardian");
    address internal outsider = makeAddr("outsider");
    address internal provider = makeAddr("provider");
    address internal borrower = makeAddr("borrower");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant DELAY = 2 days;
    bytes32 internal constant SALT = bytes32(0);

    function setUp() public {
        vm.warp(1_000 days);

        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        desk = new PartnershipDesk(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);
        pool.setGuardian(guardian);

        usdc.mint(provider, 1_000_000e6);
        usdc.mint(borrower, 1_000_000e6);
        tbill.mint(borrower, 1_000e18);
        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        tbill.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.prank(provider);
        pool.deposit(500_000e6);

        // Handover, in the order a real one happens: wire the delay, then hand over the keys.
        timelock = new SafixTimelock(multisig, DELAY);
        pool.setTimelock(address(timelock));
        desk.setTimelock(address(timelock));
        pool.setOwner(multisig);
        desk.setOwner(multisig);
    }

    function _queueAndRun(address target, bytes memory data) internal {
        vm.prank(multisig);
        timelock.queue(target, data, SALT);
        vm.warp(block.timestamp + DELAY);
        vm.prank(multisig);
        timelock.execute(target, data, SALT);
    }

    // --------------------------------------------------------------------------------------
    // the delay itself
    // --------------------------------------------------------------------------------------

    function testAChangeWaitsForTheDelay() public {
        bytes memory data = abi.encodeCall(SafixPool.setFees, (100, 60));

        vm.prank(multisig);
        bytes32 id = timelock.queue(address(pool), data, SALT);
        assertFalse(timelock.isReady(id));

        // One second short.
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(multisig);
        vm.expectRevert(bytes("too early"));
        timelock.execute(address(pool), data, SALT);

        // On the second.
        vm.warp(block.timestamp + 1);
        assertTrue(timelock.isReady(id));
        vm.prank(multisig);
        timelock.execute(address(pool), data, SALT);

        assertEq(pool.originationFeeBps(), 100);
        assertEq(pool.redemptionFeeBps(), 60);
        assertEq(timelock.queuedAt(id), 0, "the operation should be consumed");
    }

    function testAnOperationGoesStaleAfterTheGracePeriod() public {
        bytes memory data = abi.encodeCall(SafixPool.setFees, (100, 60));
        vm.prank(multisig);
        bytes32 id = timelock.queue(address(pool), data, SALT);

        vm.warp(block.timestamp + DELAY + timelock.GRACE_PERIOD() + 1);
        assertFalse(timelock.isReady(id));
        vm.prank(multisig);
        vm.expectRevert(bytes("expired"));
        timelock.execute(address(pool), data, SALT);

        // A change nobody remembers cannot be executed years later.
        assertEq(pool.originationFeeBps(), 50);
    }

    function testAQueuedChangeCanBeCancelledImmediately() public {
        bytes memory data = abi.encodeCall(SafixPool.setFees, (500, 500));
        vm.prank(multisig);
        bytes32 id = timelock.queue(address(pool), data, SALT);

        // Stopping a change is never the thing that needs slowing down.
        vm.prank(multisig);
        timelock.cancel(address(pool), data, SALT);
        assertEq(timelock.queuedAt(id), 0);

        vm.warp(block.timestamp + DELAY);
        vm.prank(multisig);
        vm.expectRevert(bytes("not queued"));
        timelock.execute(address(pool), data, SALT);
    }

    function testTheSameOperationCannotBeQueuedTwiceUnderOneSalt() public {
        bytes memory data = abi.encodeCall(SafixPool.setFees, (100, 60));
        vm.startPrank(multisig);
        timelock.queue(address(pool), data, SALT);
        vm.expectRevert(bytes("already queued"));
        timelock.queue(address(pool), data, SALT);

        // A different salt is a different operation, which is how the same change is queued twice.
        timelock.queue(address(pool), data, bytes32(uint256(1)));
        vm.stopPrank();
    }

    function testOnlyTheAdminDrivesTheTimelock() public {
        bytes memory data = abi.encodeCall(SafixPool.setFees, (100, 60));
        vm.startPrank(outsider);
        vm.expectRevert(bytes("not admin"));
        timelock.queue(address(pool), data, SALT);
        vm.expectRevert(bytes("not admin"));
        timelock.execute(address(pool), data, SALT);
        vm.expectRevert(bytes("not admin"));
        timelock.cancel(address(pool), data, SALT);
        vm.stopPrank();
    }

    function testAFailedCallSurfacesTheTargetsOwnReason() public {
        // 600 bps is past the pool's own fee ceiling.
        bytes memory data = abi.encodeCall(SafixPool.setFees, (600, 60));
        vm.prank(multisig);
        timelock.queue(address(pool), data, SALT);
        vm.warp(block.timestamp + DELAY);
        vm.prank(multisig);
        vm.expectRevert(bytes("fee too high"));
        timelock.execute(address(pool), data, SALT);
    }

    // --------------------------------------------------------------------------------------
    // the timelock's own settings are behind the timelock
    // --------------------------------------------------------------------------------------

    function testShorteningTheDelayGoesThroughTheDelay() public {
        // The admin cannot reach it directly, or the delay would be one transaction from nothing.
        vm.prank(multisig);
        vm.expectRevert(bytes("not timelock"));
        timelock.setDelay(1 days);

        _queueAndRun(address(timelock), abi.encodeCall(SafixTimelock.setDelay, (3 days)));
        assertEq(timelock.delay(), 3 days);
    }

    function testTheDelayHasAFloorThatCannotBeCrossed() public {
        vm.expectRevert(bytes("delay too short"));
        new SafixTimelock(multisig, 1 hours);

        bytes memory data = abi.encodeCall(SafixTimelock.setDelay, (1 hours));
        vm.prank(multisig);
        timelock.queue(address(timelock), data, SALT);
        vm.warp(block.timestamp + DELAY);
        vm.prank(multisig);
        vm.expectRevert(bytes("delay too short"));
        timelock.execute(address(timelock), data, SALT);
    }

    function testReplacingTheMultisigGoesThroughTheDelay() public {
        address nextMultisig = makeAddr("nextMultisig");
        vm.prank(multisig);
        vm.expectRevert(bytes("not timelock"));
        timelock.setAdmin(nextMultisig);

        _queueAndRun(address(timelock), abi.encodeCall(SafixTimelock.setAdmin, (nextMultisig)));
        assertEq(timelock.admin(), nextMultisig);
    }

    // --------------------------------------------------------------------------------------
    // what is behind the delay, and what is not
    // --------------------------------------------------------------------------------------

    function testRiskParametersAreOutOfTheMultisigsDirectReach() public {
        vm.startPrank(multisig);
        vm.expectRevert(bytes("not timelock"));
        pool.setFees(100, 60);
        vm.expectRevert(bytes("not timelock"));
        pool.configureAsset(address(tbill), 7000, 8000, 100e18);
        vm.expectRevert(bytes("not timelock"));
        pool.setAssetCaps(address(tbill), 1e6, 1e18);
        vm.expectRevert(bytes("not timelock"));
        pool.setRiskLimits(1, 1, 1);
        vm.expectRevert(bytes("not timelock"));
        pool.setPriceFeed(address(tbill), address(0));
        vm.expectRevert(bytes("not timelock"));
        pool.setPriceGuard(address(tbill), 1 days, 1000, 1e18, 2e18);
        vm.expectRevert(bytes("not timelock"));
        pool.setLiquidationIncentive(100);
        vm.expectRevert(bytes("not timelock"));
        pool.setReserveFeeShare(1000);
        vm.expectRevert(bytes("not timelock"));
        desk.setAuditor(outsider);
        vm.stopPrank();
    }

    function testEachRiskParameterCanStillBeChangedThroughTheDelay() public {
        _queueAndRun(address(pool), abi.encodeCall(SafixPool.setFees, (100, 60)));
        assertEq(pool.originationFeeBps(), 100);

        _queueAndRun(address(pool), abi.encodeCall(SafixPool.setAssetCaps, (address(tbill), 50_000e6, 500e18)));
        (,,,, uint256 debtCap,) = pool.assetConfig(address(tbill));
        assertEq(debtCap, 50_000e6);

        _queueAndRun(address(pool), abi.encodeCall(SafixPool.setRiskLimits, (100_000e6, 500e6, 1_000e6)));
        assertEq(pool.globalDebtCeiling(), 100_000e6);

        _queueAndRun(address(pool), abi.encodeCall(SafixPool.setReserveFeeShare, (2_500)));
        assertEq(pool.reserveFeeShareBps(), 2_500);

        _queueAndRun(address(desk), abi.encodeCall(PartnershipDesk.setAuditor, (outsider)));
        assertEq(desk.auditor(), outsider);
    }

    function testTheBrakeIsNotBehindTheDelay() public {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.draw(address(tbill), 5_000e6);
        vm.stopPrank();

        // Read the constant before any prank, or the view call is what gets pranked.
        uint8 all = pool.PAUSE_ALL();

        // The guardian stops the protocol in the block it decides to, timelock or no timelock.
        uint256 blockBefore = block.number;
        vm.prank(guardian);
        pool.pause(all);
        assertEq(block.number, blockBefore);
        assertEq(pool.pausedActions(), 7);

        // And the multisig restarts it directly: an incident is not the moment to wait two days.
        vm.prank(multisig);
        pool.unpause(all);
        assertEq(pool.pausedActions(), 0);
    }

    function testOperationalActionsStayWithTheMultisig() public {
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.draw(address(tbill), 5_000e6);
        vm.stopPrank();

        vm.startPrank(multisig);
        // None of these change what a position is worth or when it is liquidated.
        pool.setGuardian(outsider);
        pool.setPriceUpdater(outsider);
        pool.collectProtocolFees(treasury);
        pool.setPassportRegistry(address(0));
        vm.stopPrank();

        assertEq(pool.guardian(), outsider);
        assertGt(usdc.balanceOf(treasury), 0);
    }

    function testThePriceUpdaterStillWorksAtKeeperSpeed() public {
        vm.prank(multisig);
        pool.setPriceUpdater(outsider);

        // A price is not a parameter: it changes every heartbeat and cannot wait two days.
        vm.prank(outsider);
        pool.setPrice(address(tbill), 99e18);
        (uint256 price,) = pool.currentPrice(address(tbill));
        assertEq(price, 99e18);
    }

    function testTheReserveCannotBePulledWithoutNotice() public {
        // Funding stays open to anyone and instant: adding to the buffer never hurts a lender.
        vm.prank(provider);
        pool.fundReserve(10_000e6);
        assertEq(pool.reserve(), 10_000e6);

        // The multisig owns the pool and still cannot take the buffer back in one transaction.
        // Emptying it touches no deposit, but it decides who carries the next shortfall.
        vm.prank(multisig);
        vm.expectRevert(bytes("not timelock"));
        pool.withdrawReserve(treasury, 10_000e6);

        // It has to announce it. The calldata sits in the Queued event for the whole delay, so a
        // provider, or whoever funded the reserve, sees it coming and can leave first.
        bytes memory data = abi.encodeCall(SafixPool.withdrawReserve, (treasury, 10_000e6));
        vm.prank(multisig);
        bytes32 id = timelock.queue(address(pool), data, SALT);

        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(multisig);
        vm.expectRevert(bytes("too early"));
        timelock.execute(address(pool), data, SALT);
        assertEq(pool.reserve(), 10_000e6, "the reserve moved before the delay ran out");

        vm.warp(block.timestamp + 1);
        assertTrue(timelock.isReady(id));
        vm.prank(multisig);
        timelock.execute(address(pool), data, SALT);
        assertEq(pool.reserve(), 0);
        assertEq(usdc.balanceOf(treasury), 10_000e6);
    }

    // --------------------------------------------------------------------------------------
    // handover
    // --------------------------------------------------------------------------------------

    function testNoEoaRetainsAPrivilegedRoleAfterHandover() public view {
        // The deployer of this test contract is the EOA stand-in; it configured everything and then
        // handed over. It must hold nothing afterwards.
        assertEq(pool.owner(), multisig);
        assertEq(desk.owner(), multisig);
        assertEq(pool.timelock(), address(timelock));
        assertEq(desk.timelock(), address(timelock));
        assertEq(timelock.admin(), multisig);
        assertTrue(pool.owner() != address(this));
        assertTrue(desk.owner() != address(this));
    }

    function testTheOldOwnerLosesEverythingAtOnce() public {
        // address(this) configured the pool in setUp and is now nobody.
        vm.expectRevert(bytes("not owner"));
        pool.setGuardian(outsider);
        vm.expectRevert(bytes("not timelock"));
        pool.setFees(100, 60);
        vm.expectRevert(bytes("not owner"));
        pool.collectProtocolFees(treasury);
        // The gate moved behind itself, so the old owner is refused as not the timelock rather
        // than as not the owner. Either way it cannot reach it.
        vm.expectRevert(bytes("not timelock"));
        pool.setTimelock(address(0));
    }

    function testBeforeATimelockIsWiredTheOwnerStillConfigures() public {
        // A fresh deployment has no timelock, and has to be configurable to be set up at all.
        SafixPool fresh = new SafixPool(address(usdc));
        assertEq(fresh.timelock(), address(0));
        fresh.configureAsset(address(tbill), 8000, 9000, 100e18);
        fresh.setAssetCaps(address(tbill), 1_000e6, 10e18);
        fresh.setFees(60, 40);
        assertEq(fresh.originationFeeBps(), 60);

        // The moment one is wired, that door closes.
        fresh.setTimelock(address(timelock));
        vm.expectRevert(bytes("not timelock"));
        fresh.setFees(70, 40);
    }

    /// The delay is only a delay if the gate itself is behind it. `setTimelock` used to be
    /// `onlyOwner`, so the owner could point the timelock at itself and then change an LTV, a fee,
    /// a price feed or a cap in the same transaction, with none of the notice the delay exists to
    /// give. The owner now cannot move the gate at all; moving it is itself a queued operation.
    function testTheOwnerCannotPointTheTimelockAtItselfAndSkipTheDelay() public {
        vm.prank(multisig);
        vm.expectRevert(bytes("not timelock"));
        pool.setTimelock(multisig);

        vm.prank(multisig);
        vm.expectRevert(bytes("not timelock"));
        desk.setTimelock(multisig);

        vm.prank(multisig);
        vm.expectRevert(bytes("not timelock"));
        pool.configureAsset(address(tbill), 9900, 9901, 100e18);

        vm.prank(multisig);
        vm.expectRevert(bytes("not timelock"));
        desk.setAuditor(multisig);

        SafixTimelock replacement = new SafixTimelock(multisig, DELAY);
        _queueAndRun(address(pool), abi.encodeCall(SafixPool.setTimelock, (address(replacement))));
        assertEq(pool.timelock(), address(replacement));
    }
}
