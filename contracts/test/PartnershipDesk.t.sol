// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PartnershipDesk} from "../src/PartnershipDesk.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract PartnershipDeskTest is Test {
    PartnershipDesk internal desk;
    MockERC20 internal usdc;

    address internal operator = makeAddr("operator");
    address internal funderA = makeAddr("funderA");
    address internal funderB = makeAddr("funderB");

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        desk = new PartnershipDesk(address(usdc));

        usdc.mint(funderA, 200_000e6);
        usdc.mint(funderB, 200_000e6);
        usdc.mint(operator, 200_000e6);

        vm.prank(funderA);
        usdc.approve(address(desk), type(uint256).max);
        vm.prank(funderB);
        usdc.approve(address(desk), type(uint256).max);
        vm.prank(operator);
        usdc.approve(address(desk), type(uint256).max);
    }

    function _createAndFund() internal returns (uint256 id) {
        id = desk.createPartnership(operator, 4000, 100_000e6, uint64(block.timestamp + 7 days));
        vm.prank(funderA);
        desk.fund(id, 60_000e6);
        vm.prank(funderB);
        desk.fund(id, 40_000e6);
    }

    function testProfitableCycleSplitsSixtyForty() public {
        uint256 id = _createAndFund();
        desk.activate(id);
        assertEq(usdc.balanceOf(operator), 300_000e6);

        vm.prank(operator);
        desk.reportReturn(id, 130_000e6);
        desk.settle(id);

        assertEq(desk.profitOf(id), 30_000e6);
        assertEq(desk.operatorShareOf(id), 12_000e6);
        assertEq(desk.funderPayoutOf(id, funderA), 70_800e6);
        assertEq(desk.funderPayoutOf(id, funderB), 47_200e6);

        vm.prank(funderA);
        desk.claim(id);
        vm.prank(funderB);
        desk.claim(id);
        vm.prank(operator);
        desk.claimOperator(id);

        assertEq(usdc.balanceOf(funderA), 200_000e6 - 60_000e6 + 70_800e6);
        assertEq(usdc.balanceOf(funderB), 200_000e6 - 40_000e6 + 47_200e6);
        assertEq(usdc.balanceOf(operator), 300_000e6 - 130_000e6 + 12_000e6);
        assertEq(usdc.balanceOf(address(desk)), 0);
    }

    function testLossFallsOnCapital() public {
        uint256 id = _createAndFund();
        desk.activate(id);

        vm.prank(operator);
        desk.reportReturn(id, 80_000e6);
        desk.settle(id);

        assertEq(desk.profitOf(id), 0);
        assertEq(desk.operatorShareOf(id), 0);
        assertEq(desk.funderPayoutOf(id, funderA), 48_000e6);
        assertEq(desk.funderPayoutOf(id, funderB), 32_000e6);

        vm.prank(funderA);
        desk.claim(id);
        assertEq(usdc.balanceOf(funderA), 200_000e6 - 60_000e6 + 48_000e6);
    }

    function testCancelRefundsContribution() public {
        uint256 id = _createAndFund();
        desk.cancel(id);

        assertEq(desk.funderPayoutOf(id, funderA), 60_000e6);
        vm.prank(funderA);
        desk.claim(id);
        assertEq(usdc.balanceOf(funderA), 200_000e6);
    }

    function testGuards() public {
        uint256 id = _createAndFund();

        vm.prank(funderA);
        vm.expectRevert(bytes("bad amount"));
        desk.fund(id, 1e6);

        vm.prank(funderA);
        vm.expectRevert(bytes("not owner"));
        desk.activate(id);

        desk.activate(id);

        vm.prank(funderA);
        vm.expectRevert(bytes("not operator"));
        desk.reportReturn(id, 1e6);

        vm.prank(funderA);
        vm.expectRevert(bytes("not claimable"));
        desk.claim(id);

        vm.prank(operator);
        desk.reportReturn(id, 100_000e6);
        desk.settle(id);

        vm.startPrank(funderA);
        desk.claim(id);
        vm.expectRevert(bytes("nothing to claim"));
        desk.claim(id);
        vm.stopPrank();
    }

    function testFundAfterDeadlineReverts() public {
        uint256 id = desk.createPartnership(operator, 4000, 100_000e6, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        vm.prank(funderA);
        vm.expectRevert(bytes("past deadline"));
        desk.fund(id, 1_000e6);
    }
}
