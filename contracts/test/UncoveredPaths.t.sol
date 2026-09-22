// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockAggregatorV3} from "../src/MockAggregatorV3.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {PassportRegistry} from "../src/PassportRegistry.sol";
import {SafixPool} from "../src/SafixPool.sol";

/**
 * The paths coverage showed nothing reaching.
 *
 * Every one of them is somewhere an auditor looks first: a cap that is never
 * proven to bind, a setter that hands over a whole contract, an oracle's failure
 * branch, and the arithmetic a deposit meets after it has been wiped out twice.
 * Code that is never executed is code nobody has checked, whatever its comment
 * claims.
 */
contract UncoveredPathsTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal tbill;
    PassportRegistry internal registry;

    address internal provider = makeAddr("provider");
    address internal funder = makeAddr("funder");
    address internal borrower = makeAddr("borrower");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        registry = new PassportRegistry();
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);

        usdc.mint(provider, 10_000_000e6);
        usdc.mint(funder, 100_000_000e6);
        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(funder);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(borrower);
        tbill.approve(address(pool), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------
    // caps that have to bind
    // ---------------------------------------------------------------------------------------

    function testLiquidationIncentiveIsCappedAtTwoPercent() public {
        pool.setLiquidationIncentive(200);
        assertEq(pool.liquidationIncentiveBps(), 200);

        // A cap nobody has watched refuse is a cap nobody has checked.
        vm.expectRevert("too high");
        pool.setLiquidationIncentive(201);
        assertEq(pool.liquidationIncentiveBps(), 200);
    }

    // ---------------------------------------------------------------------------------------
    // the registry's own ownership
    // ---------------------------------------------------------------------------------------

    function testRegistryOwnerCanBeHandedOverAndTheOldOwnerLosesIt() public {
        registry.setOwner(stranger);
        assertEq(registry.owner(), stranger);

        // The handover is the whole of the registry's authority, so the old owner
        // keeping any of it would be the failure worth catching.
        vm.expectRevert("not owner");
        registry.setOwner(address(this));

        vm.prank(stranger);
        registry.setOwner(address(this));
        assertEq(registry.owner(), address(this));
    }

    function testRegistryRefusesTheZeroOwner() public {
        vm.expectRevert("zero owner");
        registry.setOwner(address(0));
        assertEq(registry.owner(), address(this));
    }

    // ---------------------------------------------------------------------------------------
    // the accounting after a deposit is gone
    // ---------------------------------------------------------------------------------------

    function testADepositWipedAcrossTwoScalesIsWorthNothingRatherThanSomething() public {
        // One provider deposits once and never again, so its snapshot stays where it
        // was. Another funds the rounds that empty the pool. Depositing again would
        // move the first one's snapshot forward and it would never fall two scales
        // behind, which is what the earlier version of this test did to itself.
        vm.prank(provider);
        pool.deposit(10_000e6);
        assertGt(pool.compoundedDepositOf(provider), 0);

        _rollScale();
        _rollScale();

        // Two rollovers past its own scale is past what the compounding can
        // represent. Nothing is owed, and saying so is the point: the arithmetic
        // would otherwise divide by a P from a scale that no longer means what it
        // meant, and answer with a number that looks like money.
        assertGe(pool.currentScale(), 2);
        assertEq(pool.compoundedDepositOf(provider), 0);
    }

    // ---------------------------------------------------------------------------------------
    // the oracle's own failure
    // ---------------------------------------------------------------------------------------

    function testAFeedThatLostItsHistoryStillPricesTheAsset() public {
        MockERC20 bnvda = new MockERC20("Tokenized Nvidia", "bNVDA", 18);
        pool.configureAsset(address(bnvda), 5500, 7000, 1e18);

        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.setAnswer(172.35e8);
        pool.setPriceFeed(address(bnvda), address(feed));
        // A deviation limit is what makes the pool reach for the round before this one.
        pool.setPriceGuard(address(bnvda), 1 days, 1000, 0, 0);
        feed.setAnswer(172.40e8);

        (SafixPool.PriceStatus ok,,) = pool.priceStatus(address(bnvda));
        assertEq(uint8(ok), uint8(SafixPool.PriceStatus.Ok));

        // An aggregator upgrade leaves the latest answer readable and the round
        // before it gone. Refusing the asset for that would freeze a perfectly good
        // price because its history moved, so the comparison is skipped instead: a
        // missing past is not evidence of a bad present.
        feed.setRevertingHistory(true);
        (SafixPool.PriceStatus afterLoss, uint256 price,) = pool.priceStatus(address(bnvda));
        assertEq(uint8(afterLoss), uint8(SafixPool.PriceStatus.Ok));
        assertEq(price, 172.40e18);

        // The feed failing outright is a different thing and still refused.
        feed.setReverting(true);
        (SafixPool.PriceStatus down,,) = pool.priceStatus(address(bnvda));
        assertEq(uint8(down), uint8(SafixPool.PriceStatus.FeedUnavailable));
    }

    // ---------------------------------------------------------------------------------------
    // the views nothing called
    // ---------------------------------------------------------------------------------------

    function testAssetCountFollowsWhatIsConfigured() public {
        assertEq(pool.assetCount(), 1);
        MockERC20 gold = new MockERC20("Tokenized gold", "tGOLD", 18);
        pool.configureAsset(address(gold), 7000, 8000, 3000e18);
        assertEq(pool.assetCount(), 2);

        // Reconfiguring is not a second asset.
        pool.configureAsset(address(gold), 6000, 8000, 3000e18);
        assertEq(pool.assetCount(), 2);
    }

    // ---------------------------------------------------------------------------------------

    /// @dev Empties the pool through a liquidation until the scale rolls over once more.
    function _rollScale() internal {
        uint256 scaleBefore = pool.currentScale();
        for (uint256 guard = 0; guard < 25 && pool.currentScale() == scaleBefore; guard++) {
            uint256 total = pool.totalDeposits();
            if (total < 10_000e6) {
                vm.prank(funder);
                pool.deposit(10_000e6 - total);
            }
            uint256 draw = (pool.availableLiquidity() * 99) / 100;
            uint256 collateral = (draw + (draw * 50) / 10_000) * 13e9;
            tbill.mint(borrower, collateral);
            vm.startPrank(borrower);
            pool.lockCollateral(address(tbill), collateral);
            pool.draw(address(tbill), draw);
            vm.stopPrank();

            pool.setPrice(address(tbill), 1e18);
            vm.prank(keeper);
            pool.liquidate(borrower, address(tbill), type(uint256).max);
            pool.setPrice(address(tbill), 100e18);

            vm.prank(borrower);
            usdc.transfer(funder, draw);
        }
        assertGt(pool.currentScale(), scaleBefore);
    }
}
