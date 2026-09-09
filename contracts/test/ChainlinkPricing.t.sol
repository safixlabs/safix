// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockAggregatorV3} from "../src/MockAggregatorV3.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract ChainlinkPricingTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal bnvda;
    MockAggregatorV3 internal feed;

    address internal provider = makeAddr("provider");
    address internal borrower = makeAddr("borrower");

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        bnvda = new MockERC20("Tokenized Nvidia", "bNVDA", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(bnvda), 5500, 7000, 1e18);

        feed = new MockAggregatorV3(8);
        feed.setAnswer(172.35e8);
        pool.setPriceFeed(address(bnvda), address(feed));

        usdc.mint(provider, 100_000e6);
        bnvda.mint(borrower, 100e18);

        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(provider);
        pool.deposit(50_000e6);
        vm.startPrank(borrower);
        bnvda.approve(address(pool), type(uint256).max);
        pool.lockCollateral(address(bnvda), 100e18);
        vm.stopPrank();
    }

    function testFeedDrivesValuation() public view {
        (uint256 price, uint256 updatedAt) = pool.currentPrice(address(bnvda));
        assertEq(price, 172.35e18);
        assertEq(updatedAt, block.timestamp);
        assertEq(pool.collateralValueStable(address(bnvda), 100e18), 17_235e6);
    }

    function testDrawUsesFeedPrice() public {
        vm.prank(borrower);
        pool.draw(address(bnvda), 9_000e6);

        feed.setAnswer(80e8);
        assertTrue(pool.isLiquidatable(borrower, address(bnvda)));
    }

    function testStaleFeedBlocksDraw() public {
        pool.setPriceGuard(address(bnvda), 1 hours, 0, 0, 0);
        feed.setAnswerAt(172.35e8, block.timestamp);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(borrower);
        vm.expectRevert(bytes("stale price"));
        pool.draw(address(bnvda), 1_000e6);
    }

    function testBadAnswerReverts() public {
        feed.setAnswer(0);
        vm.prank(borrower);
        vm.expectRevert(bytes("feed unavailable"));
        pool.draw(address(bnvda), 1_000e6);

        // The status view says the same thing without reverting, so a keeper can keep scanning.
        (SafixPool.PriceStatus status,,) = pool.priceStatus(address(bnvda));
        assertEq(uint256(status), uint256(SafixPool.PriceStatus.FeedUnavailable));
        assertFalse(pool.isLiquidatable(borrower, address(bnvda)));
    }

    function testFeedDecimalsGuard() public {
        MockAggregatorV3 wideFeed = new MockAggregatorV3(19);
        vm.expectRevert(bytes("bad feed decimals"));
        pool.setPriceFeed(address(bnvda), address(wideFeed));
    }

    function testRemovingFeedFallsBackToManualPrice() public {
        pool.setPriceFeed(address(bnvda), address(0));
        pool.setPrice(address(bnvda), 3e18);
        (uint256 price,) = pool.currentPrice(address(bnvda));
        assertEq(price, 3e18);
    }
}
