// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockAggregatorV3} from "../src/MockAggregatorV3.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Every way a price can be untrustworthy, and what the pool does about it.
///
/// The rule the pool follows: a price that cannot be trusted blocks anything that puts a borrower
/// at risk (draws, liquidations, withdrawing collateral against a live loan) and blocks nothing
/// that lets a borrower or a provider get out (repay, close, claim, withdraw liquidity, and
/// withdrawing collateral that has no debt against it).
contract OracleSafetyTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal bnvda;
    MockERC20 internal tbill;
    MockAggregatorV3 internal feed;
    MockAggregatorV3 internal sequencer;

    address internal provider = makeAddr("provider");
    address internal borrower = makeAddr("borrower");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant GRACE = 1 hours;

    function setUp() public {
        // Start well clear of zero so "startedAt in the past" is expressible.
        vm.warp(1_000 days);

        usdc = new MockERC20("Mock USDC", "USDC", 6);
        bnvda = new MockERC20("Tokenized Nvidia", "bNVDA", 18);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(bnvda), 5500, 7000, 1e18);
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);

        feed = new MockAggregatorV3(8);
        feed.setAnswer(100e8);
        pool.setPriceFeed(address(bnvda), address(feed));

        sequencer = new MockAggregatorV3(0);

        usdc.mint(provider, 1_000_000e6);
        usdc.mint(borrower, 100_000e6);
        bnvda.mint(borrower, 1_000e18);
        tbill.mint(borrower, 1_000e18);

        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(provider);
        pool.deposit(200_000e6);

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        bnvda.approve(address(pool), type(uint256).max);
        tbill.approve(address(pool), type(uint256).max);
        pool.lockCollateral(address(bnvda), 100e18);
        vm.stopPrank();
    }

    function _status(address asset) internal view returns (SafixPool.PriceStatus) {
        (SafixPool.PriceStatus status,,) = pool.priceStatus(asset);
        return status;
    }

    /// @dev Opens a position that a later price move can make liquidatable.
    function _borrow(uint256 amount) internal {
        vm.prank(borrower);
        pool.draw(address(bnvda), amount);
    }

    /// @dev Sequencer up, and up for long enough that the grace period has elapsed.
    function _sequencerUpAndSettled() internal {
        sequencer.setRound(0, block.timestamp - GRACE - 1, block.timestamp - GRACE - 1);
        pool.setSequencerUptimeFeed(address(sequencer), GRACE);
    }

    // --------------------------------------------------------------------------------------
    // sequencer down
    // --------------------------------------------------------------------------------------

    function testSequencerDownBlocksDrawAndLiquidation() public {
        _borrow(5_000e6);

        // The position is genuinely underwater...
        feed.setAnswer(60e8);
        assertTrue(pool.isLiquidatable(borrower, address(bnvda)));

        // ...but the sequencer went down, so nobody could have reacted to that price.
        sequencer.setRound(1, block.timestamp, block.timestamp);
        pool.setSequencerUptimeFeed(address(sequencer), GRACE);

        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.SequencerDown));
        assertFalse(pool.isLiquidatable(borrower, address(bnvda)));

        vm.expectRevert(bytes("sequencer down"));
        pool.liquidate(borrower, address(bnvda), type(uint256).max);

        vm.prank(borrower);
        vm.expectRevert(bytes("sequencer down"));
        pool.draw(address(bnvda), 1e6);
    }

    function testSequencerFeedRevertingCountsAsDown() public {
        pool.setSequencerUptimeFeed(address(sequencer), GRACE);
        sequencer.setRound(0, block.timestamp - GRACE - 1, block.timestamp - GRACE - 1);
        sequencer.setReverting(true);

        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.SequencerDown));
        vm.prank(borrower);
        vm.expectRevert(bytes("sequencer down"));
        pool.draw(address(bnvda), 1e6);
    }

    function testSequencerRoundNeverStartedCountsAsDown() public {
        // answer 0 looks like "up", but startedAt 0 means the feed has never reported.
        sequencer.setRound(0, 0, 0);
        pool.setSequencerUptimeFeed(address(sequencer), GRACE);

        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.SequencerDown));
    }

    // --------------------------------------------------------------------------------------
    // grace period
    // --------------------------------------------------------------------------------------

    function testGracePeriodBlocksLiquidationAfterRecovery() public {
        _borrow(5_000e6);
        feed.setAnswer(60e8);

        // The sequencer just came back this second.
        sequencer.setRound(0, block.timestamp, block.timestamp);
        pool.setSequencerUptimeFeed(address(sequencer), GRACE);

        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.SequencerGracePeriod));
        assertFalse(pool.isLiquidatable(borrower, address(bnvda)));

        vm.expectRevert(bytes("sequencer grace period"));
        pool.liquidate(borrower, address(bnvda), type(uint256).max);

        vm.prank(borrower);
        vm.expectRevert(bytes("sequencer grace period"));
        pool.draw(address(bnvda), 1e6);

        // The boundary itself is still inside the window.
        vm.warp(block.timestamp + GRACE);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.SequencerGracePeriod));

        // One second past it, the pool trusts prices again.
        vm.warp(block.timestamp + 1);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.Ok));
        assertTrue(pool.isLiquidatable(borrower, address(bnvda)));

        vm.prank(keeper);
        pool.liquidate(borrower, address(bnvda), type(uint256).max);
        (, uint256 debt,) = pool.positions(borrower, address(bnvda));
        assertEq(debt, 0);
    }

    function testBorrowerCanRepayDuringGracePeriod() public {
        _borrow(5_000e6);
        feed.setAnswer(60e8);
        sequencer.setRound(0, block.timestamp, block.timestamp);
        pool.setSequencerUptimeFeed(address(sequencer), GRACE);

        // The grace period exists so this is possible: get healthy before liquidations resume.
        vm.prank(borrower);
        pool.repay(address(bnvda), 4_000e6);

        vm.warp(block.timestamp + GRACE + 1);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.Ok));
        assertFalse(pool.isLiquidatable(borrower, address(bnvda)));
    }

    // --------------------------------------------------------------------------------------
    // sanity bounds
    // --------------------------------------------------------------------------------------

    function testPriceBelowBandBlocksDrawAndLiquidation() public {
        _borrow(1_000e6);
        pool.setPriceGuard(address(bnvda), 0, 0, 50e18, 200e18);

        feed.setAnswer(10e8);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.BelowBand));
        assertFalse(pool.isLiquidatable(borrower, address(bnvda)));

        vm.prank(borrower);
        vm.expectRevert(bytes("price below band"));
        pool.draw(address(bnvda), 1e6);

        vm.expectRevert(bytes("price below band"));
        pool.liquidate(borrower, address(bnvda), type(uint256).max);
    }

    function testPriceAboveBandBlocksDraw() public {
        pool.setPriceGuard(address(bnvda), 0, 0, 50e18, 200e18);

        feed.setAnswer(5_000e8);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.AboveBand));

        vm.prank(borrower);
        vm.expectRevert(bytes("price above band"));
        pool.draw(address(bnvda), 1e6);
    }

    function testPriceInsideBandStillWorks() public {
        pool.setPriceGuard(address(bnvda), 0, 0, 50e18, 200e18);
        feed.setAnswer(150e8);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.Ok));

        vm.prank(borrower);
        pool.draw(address(bnvda), 1_000e6);
        (, uint256 debt,) = pool.positions(borrower, address(bnvda));
        assertEq(debt, 1_005e6);
    }

    function testBandRejectsAnInvertedConfiguration() public {
        vm.expectRevert(bytes("bad band"));
        pool.setPriceGuard(address(bnvda), 0, 0, 200e18, 50e18);
    }

    // --------------------------------------------------------------------------------------
    // sudden jump between updates
    // --------------------------------------------------------------------------------------

    function testSuddenJumpBetweenRoundsBlocksDraw() public {
        // Ten percent is as far as this asset may move between two feed updates.
        pool.setPriceGuard(address(bnvda), 0, 1_000, 0, 0);

        // A move inside the limit is fine.
        feed.setAnswer(105e8);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.Ok));

        // A 50% collapse in one round is not.
        feed.setAnswer(52e8);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.DeviationTooLarge));

        vm.prank(borrower);
        vm.expectRevert(bytes("price jump"));
        pool.draw(address(bnvda), 1e6);
    }

    function testSuddenJumpBlocksLiquidationOnTheJumpItself() public {
        _borrow(5_000e6);
        pool.setPriceGuard(address(bnvda), 0, 1_000, 0, 0);

        // A print that would liquidate the position, arriving as a single 40% gap.
        feed.setAnswer(60e8);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.DeviationTooLarge));
        assertFalse(pool.isLiquidatable(borrower, address(bnvda)));

        vm.expectRevert(bytes("price jump"));
        pool.liquidate(borrower, address(bnvda), type(uint256).max);

        // Once the move is confirmed by a second round at the new level, it is actionable.
        feed.setAnswer(59e8);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.Ok));
        assertTrue(pool.isLiquidatable(borrower, address(bnvda)));
        vm.prank(keeper);
        pool.liquidate(borrower, address(bnvda), type(uint256).max);
    }

    function testManualPriceIsHeldToTheSameBoundsAsAFeed() public {
        pool.setPriceGuard(address(tbill), 0, 1_000, 90e18, 110e18);

        vm.expectRevert(bytes("price below band"));
        pool.setPrice(address(tbill), 80e18);

        vm.expectRevert(bytes("price above band"));
        pool.setPrice(address(tbill), 120e18);

        // Inside the band but a 9% move from 100: allowed.
        pool.setPrice(address(tbill), 109e18);

        // From 109, a move to 95 is 12.8%: refused.
        vm.expectRevert(bytes("price jump"));
        pool.setPrice(address(tbill), 95e18);
    }

    // --------------------------------------------------------------------------------------
    // staleness, per asset
    // --------------------------------------------------------------------------------------

    function testMaxPriceAgeIsPerAssetNotGlobal() public {
        // A treasury feed on a daily heartbeat and an equity feed on an hourly one.
        pool.setPriceGuard(address(tbill), 1 days, 0, 0, 0);
        pool.setPriceGuard(address(bnvda), 1 hours, 0, 0, 0);

        vm.warp(block.timestamp + 2 hours);

        // The equity price has aged out; the treasury price has not.
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.Stale));
        assertEq(uint256(_status(address(tbill))), uint256(SafixPool.PriceStatus.Ok));

        vm.prank(borrower);
        vm.expectRevert(bytes("stale price"));
        pool.draw(address(bnvda), 1e6);

        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.draw(address(tbill), 1_000e6);
        vm.stopPrank();
    }

    function testAnAssetWithNoGuardKeepsItsPreviousBehaviour() public {
        vm.warp(block.timestamp + 3650 days);
        // No guard configured means no age limit, which is how the pool behaved before guards.
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.Ok));
        vm.prank(borrower);
        pool.draw(address(bnvda), 1_000e6);
    }

    // --------------------------------------------------------------------------------------
    // feed reverting
    // --------------------------------------------------------------------------------------

    function testFeedRevertingBlocksRiskButNeverRevertsAView() public {
        _borrow(5_000e6);
        feed.setReverting(true);

        // Views answer instead of throwing, so a keeper scanning many positions survives one bad feed.
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.FeedUnavailable));
        assertFalse(pool.isLiquidatable(borrower, address(bnvda)));

        vm.prank(borrower);
        vm.expectRevert(bytes("feed unavailable"));
        pool.draw(address(bnvda), 1e6);

        vm.expectRevert(bytes("feed unavailable"));
        pool.liquidate(borrower, address(bnvda), type(uint256).max);
    }

    // --------------------------------------------------------------------------------------
    // the exits stay open
    // --------------------------------------------------------------------------------------

    function testExitsStayOpenWhileThePriceIsUnusable() public {
        _borrow(5_000e6);

        vm.prank(provider);
        pool.deposit(1_000e6);

        // Everything at once: sequencer down and the price feed unreachable.
        sequencer.setRound(1, block.timestamp, block.timestamp);
        pool.setSequencerUptimeFeed(address(sequencer), GRACE);
        feed.setReverting(true);

        // A borrower can always reduce their own risk.
        vm.prank(borrower);
        pool.repay(address(bnvda), 2_000e6);

        // And can always get out entirely, collateral included.
        vm.prank(borrower);
        pool.closePosition(address(bnvda));
        (uint256 collateral, uint256 debt,) = pool.positions(borrower, address(bnvda));
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(bnvda.balanceOf(borrower), 1_000e18);

        // Collateral with no debt against it needs no price to release.
        vm.startPrank(borrower);
        pool.lockCollateral(address(bnvda), 50e18);
        pool.withdrawCollateral(address(bnvda), 50e18);
        vm.stopPrank();
        assertEq(bnvda.balanceOf(borrower), 1_000e18);

        // Providers are not trapped either.
        vm.prank(provider);
        pool.withdraw(1_000e6);
        address[] memory assets = new address[](1);
        assets[0] = address(bnvda);
        vm.prank(provider);
        pool.claimGains(assets);
    }

    function testWithdrawingCollateralAgainstDebtStillNeedsAPrice() public {
        _borrow(1_000e6);
        feed.setReverting(true);

        // This one raises the borrower's risk, so it is refused with the reason.
        vm.prank(borrower);
        vm.expectRevert(bytes("feed unavailable"));
        pool.withdrawCollateral(address(bnvda), 10e18);
    }

    // --------------------------------------------------------------------------------------
    // access control on the new settings
    // --------------------------------------------------------------------------------------

    function testOnlyOwnerConfiguresOracleSafety() public {
        vm.startPrank(keeper);
        vm.expectRevert(bytes("not owner"));
        pool.setSequencerUptimeFeed(address(sequencer), GRACE);
        vm.expectRevert(bytes("not owner"));
        pool.setPriceGuard(address(bnvda), 1 hours, 500, 1e18, 2e18);
        vm.stopPrank();
    }

    function testSequencerFeedCanBeRemoved() public {
        sequencer.setRound(1, block.timestamp, block.timestamp);
        pool.setSequencerUptimeFeed(address(sequencer), GRACE);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.SequencerDown));

        // Chains without a published uptime feed run with none, which is the pre-existing behaviour.
        pool.setSequencerUptimeFeed(address(0), 0);
        assertEq(uint256(_status(address(bnvda))), uint256(SafixPool.PriceStatus.Ok));
    }

    function testDisabledAssetReportsItself() public {
        assertEq(uint256(_status(makeAddr("unconfigured"))), uint256(SafixPool.PriceStatus.AssetDisabled));
    }

    /// A round dated in the future is not a price to act on, and it must not knock over the views
    /// either. Both subtractions that measure age run against an oracle's own number, so a feed
    /// reporting a timestamp ahead of the block would underflow one and revert the other.
    function testASequencerRoundDatedInTheFutureReadsAsDownRatherThanReverting() public {
        sequencer.setRound(0, block.timestamp + 1 days, block.timestamp);
        pool.setSequencerUptimeFeed(address(sequencer), GRACE);

        (SafixPool.PriceStatus status,,) = pool.priceStatus(address(bnvda));
        assertEq(uint256(status), uint256(SafixPool.PriceStatus.SequencerDown));
        assertFalse(pool.isLiquidatable(borrower, address(bnvda)));

        vm.prank(borrower);
        vm.expectRevert(bytes("sequencer down"));
        pool.draw(address(bnvda), 1e6);
    }

    function testAPriceDatedInTheFutureReadsAsStaleRatherThanReverting() public {
        pool.setPriceGuard(address(bnvda), 1 hours, 0, 0, 0);
        feed.setAnswerAt(100e8, block.timestamp + 1 days);

        (SafixPool.PriceStatus status,,) = pool.priceStatus(address(bnvda));
        assertEq(uint256(status), uint256(SafixPool.PriceStatus.Stale));
        assertFalse(pool.isLiquidatable(borrower, address(bnvda)));
    }
}
