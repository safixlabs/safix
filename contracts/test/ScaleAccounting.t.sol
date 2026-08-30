// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract ScaleAccountingTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal tbill;

    address internal provider = makeAddr("provider");
    address internal providerTwo = makeAddr("providerTwo");
    address internal borrower = makeAddr("borrower");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);

        usdc.mint(provider, 10_000_000e6);
        usdc.mint(providerTwo, 1_000_000e6);

        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(providerTwo);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(borrower);
        tbill.approve(address(pool), type(uint256).max);
    }

    function _heavyRound() internal {
        uint256 total = pool.totalDeposits();
        if (total < 10_000e6) {
            vm.prank(provider);
            pool.deposit(10_000e6 - total);
        }
        uint256 draw = (pool.availableLiquidity() * 99) / 100;
        uint256 debtEst = draw + (draw * 50) / 10_000;
        uint256 collateral = debtEst * 13e9;
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
        usdc.transfer(provider, draw);
    }

    function testScaleRolloverKeepsCompoundedAccounting() public {
        for (uint256 round = 0; round < 5; round++) {
            uint256 compBefore = 0;
            {
                uint256 target = 10_000e6;
                uint256 total = pool.totalDeposits();
                if (total < target) {
                    vm.prank(provider);
                    pool.deposit(target - total);
                }
                compBefore = pool.compoundedDepositOf(provider);
            }
            tbill.mint(borrower, 125e18);
            vm.startPrank(borrower);
            pool.lockCollateral(address(tbill), 125e18);
            pool.draw(address(tbill), 9_900e6);
            vm.stopPrank();

            pool.setPrice(address(tbill), 1e18);
            uint256 totalBefore = pool.totalDeposits();
            (, uint256 debt,) = pool.positions(borrower, address(tbill));

            vm.prank(keeper);
            pool.liquidate(borrower, address(tbill), type(uint256).max);
            pool.setPrice(address(tbill), 100e18);

            uint256 expected = (compBefore * (totalBefore - debt)) / totalBefore;
            assertApproxEqRel(pool.compoundedDepositOf(provider), expected, 1e15);
        }

        assertEq(pool.currentScale(), 1);

        uint256 expectedGain = 5 * 124.375e18;
        assertApproxEqRel(pool.gainOf(provider, address(tbill)), expectedGain, 5e15);

        address[] memory assets = new address[](1);
        assets[0] = address(tbill);
        vm.prank(provider);
        pool.claimGains(assets);
        assertApproxEqRel(tbill.balanceOf(provider), expectedGain, 5e15);
    }

    function testDepositAcrossScaleBoundaryStaysConsistent() public {
        for (uint256 round = 0; round < 3; round++) {
            _heavyRound();
        }
        assertEq(pool.currentScale(), 0);

        vm.prank(providerTwo);
        pool.deposit(10_000e6);

        uint256 guard = 0;
        while (pool.currentScale() == 0 && guard < 15) {
            _heavyRound();
            guard++;
        }
        assertEq(pool.currentScale(), 1);
        assertLt(guard, 15);
        _heavyRound();

        uint256 compA = pool.compoundedDepositOf(provider);
        uint256 compB = pool.compoundedDepositOf(providerTwo);
        assertApproxEqAbs(compA + compB, pool.totalDeposits(), 5);
        assertGt(pool.gainOf(providerTwo, address(tbill)), 0);

        address[] memory assets = new address[](1);
        assets[0] = address(tbill);
        vm.prank(provider);
        pool.claimGains(assets);
        vm.prank(providerTwo);
        pool.claimGains(assets);

        assertLt(tbill.balanceOf(address(pool)), 1e13);
    }
}
