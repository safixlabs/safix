// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PartnershipDesk} from "../src/PartnershipDesk.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice What happens when an operator goes quiet. Capital that goes out has to have a date by
///         which it comes back, or funders have no way to recover anything at all.
contract PartnershipDefaultTest is Test {
    PartnershipDesk internal desk;
    MockERC20 internal usdc;

    address internal operator = makeAddr("operator");
    address internal auditor = makeAddr("auditor");
    address internal funderOne = makeAddr("funderOne");
    address internal funderTwo = makeAddr("funderTwo");
    address internal outsider = makeAddr("outsider");

    uint64 internal fundingDeadline;
    uint64 internal reportingDeadline;

    function setUp() public {
        vm.warp(1_000 days);
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        desk = new PartnershipDesk(address(usdc));
        desk.setAuditor(auditor);

        fundingDeadline = uint64(block.timestamp + 7 days);
        reportingDeadline = uint64(block.timestamp + 180 days);

        for (uint256 i = 0; i < 3; i++) {
            address who = [funderOne, funderTwo, operator][i];
            usdc.mint(who, 1_000_000e6);
            vm.prank(who);
            usdc.approve(address(desk), type(uint256).max);
        }
    }

    /// @dev A funded, activated partnership: 60/40 between two equal funders, capital with the operator.
    function _activePartnership() internal returns (uint256 id) {
        id = desk.createPartnership(operator, 4000, 100_000e6, fundingDeadline, reportingDeadline);
        vm.prank(funderOne);
        desk.fund(id, 30_000e6);
        vm.prank(funderTwo);
        desk.fund(id, 30_000e6);
        desk.activate(id);
    }

    function testAPartnershipNeedsADateByWhichCapitalComesBack() public {
        vm.expectRevert(bytes("reporting before funding ends"));
        desk.createPartnership(operator, 4000, 100_000e6, fundingDeadline, fundingDeadline);
    }

    function testFundersRecoverAfterASilentOperator() public {
        uint256 id = _activePartnership();

        // Nothing can be declared while the deadline stands.
        vm.expectRevert(bytes("before deadline"));
        desk.declareDefault(id);

        vm.warp(reportingDeadline + 1);
        // Anyone may declare it: recovery must not wait on the owner being available.
        vm.prank(outsider);
        desk.declareDefault(id);

        uint256 before = usdc.balanceOf(funderOne);
        vm.prank(funderOne);
        desk.claim(id);
        // The operator returned nothing, so there is nothing to recover — but the claim resolves
        // rather than reverting, and the funder is no longer waiting on a settlement that will
        // never come.
        assertEq(usdc.balanceOf(funderOne) - before, 0);
        // Nothing was paid, so nothing is spent: the claim is not marked, because an operator can
        // still make good after a default and a funder who asked early must not be locked out.
        assertFalse(desk.claimed(id, funderOne));
    }

    function testAPartialReturnIsSharedProRataAndTheOperatorGetsNothing() public {
        uint256 id = _activePartnership();

        // The operator brought back 45,000 of the 60,000 they took, then went quiet.
        vm.prank(operator);
        desk.reportReturn(id, 45_000e6);

        vm.warp(reportingDeadline + 1);
        desk.declareDefault(id);

        // Equal funders, equal halves of what came back.
        assertEq(desk.funderPayoutOf(id, funderOne), 22_500e6);
        assertEq(desk.funderPayoutOf(id, funderTwo), 22_500e6);

        uint256 before = usdc.balanceOf(funderOne);
        vm.prank(funderOne);
        desk.claim(id);
        assertEq(usdc.balanceOf(funderOne) - before, 22_500e6);

        // A partnership that had to be declared in default did not earn a profit share.
        vm.prank(operator);
        vm.expectRevert(bytes("not settled"));
        desk.claimOperator(id);
    }

    function testAnOperatorCanStillMakeGoodAfterDefault() public {
        uint256 id = _activePartnership();
        vm.warp(reportingDeadline + 1);
        desk.declareDefault(id);

        // Repaying after the door closed is strictly better for the funders than stopping because
        // it closed, so the path stays open.
        vm.prank(operator);
        desk.reportReturn(id, 60_000e6);

        assertEq(desk.funderPayoutOf(id, funderOne), 30_000e6);
        vm.prank(funderOne);
        desk.claim(id);
        assertEq(usdc.balanceOf(funderOne), 1_000_000e6);
    }

    function testASettledPartnershipCannotThenBeDefaulted() public {
        uint256 id = _activePartnership();
        vm.prank(operator);
        desk.reportReturn(id, 70_000e6);
        vm.prank(auditor);
        desk.approveSettlement(id);
        desk.settle(id);

        vm.warp(reportingDeadline + 1);
        vm.expectRevert(bytes("not active"));
        desk.declareDefault(id);

        // The normal split still applies: 10,000 profit, 40% to the operator.
        assertEq(desk.operatorShareOf(id), 4_000e6);
        assertEq(desk.funderPayoutOf(id, funderOne), 33_000e6);
    }

    function testSettlingBeforeTheDeadlineIsUnaffected() public {
        uint256 id = _activePartnership();
        vm.prank(operator);
        desk.reportReturn(id, 66_000e6);
        vm.prank(auditor);
        desk.approveSettlement(id);
        desk.settle(id);

        vm.prank(funderOne);
        desk.claim(id);
        vm.prank(operator);
        desk.claimOperator(id);
        // 6,000 profit: 2,400 to the operator, 63,600 across the funders.
        assertEq(usdc.balanceOf(operator), 1_000_000e6 - 66_000e6 + 60_000e6 + 2_400e6);
    }

    function testAuditorApprovalIsStillRequiredToSettle() public {
        uint256 id = _activePartnership();
        vm.prank(operator);
        desk.reportReturn(id, 70_000e6);
        vm.expectRevert(bytes("needs audit"));
        desk.settle(id);
    }

    /// A funder who claims into an empty default and an operator who then makes good are not
    /// mutually exclusive. reportReturn stays open in Defaulted precisely so late capital can
    /// arrive, and the funder who asked first must not be the one who loses it.
    function testAnEarlyClaimDoesNotForfeitCapitalThatArrivesLater() public {
        uint256 id = _activePartnership();
        vm.warp(reportingDeadline + 1);
        vm.prank(outsider);
        desk.declareDefault(id);

        vm.prank(funderOne);
        desk.claim(id);

        vm.prank(operator);
        desk.reportReturn(id, 60_000e6);

        uint256 before = usdc.balanceOf(funderOne);
        vm.prank(funderOne);
        desk.claim(id);
        assertEq(usdc.balanceOf(funderOne) - before, 30_000e6);
        assertTrue(desk.claimed(id, funderOne));

        uint256 second = usdc.balanceOf(funderTwo);
        vm.prank(funderTwo);
        desk.claim(id);
        assertEq(usdc.balanceOf(funderTwo) - second, 30_000e6);
        assertEq(usdc.balanceOf(address(desk)), 0);
    }

    /// Capital that came back is not a default, whoever is slow to settle. Without this an
    /// operator who performed loses their share to a permissionless call one second past the
    /// deadline, because settle refuses a defaulted partnership and claimOperator needs a settled
    /// one. A partial return is still a default, so this cannot be used to block recovery.
    function testAPerformingOperatorCannotBeDefaultedOutOfTheirShare() public {
        uint256 id = _activePartnership();
        vm.prank(operator);
        desk.reportReturn(id, 80_000e6);

        vm.warp(reportingDeadline + 1);
        vm.prank(outsider);
        vm.expectRevert(bytes("capital returned"));
        desk.declareDefault(id);

        vm.prank(auditor);
        desk.approveSettlement(id);
        desk.settle(id);

        uint256 before = usdc.balanceOf(operator);
        vm.prank(operator);
        desk.claimOperator(id);
        assertEq(usdc.balanceOf(operator) - before, 8_000e6);
    }

    function testAPartialReturnIsStillADefault() public {
        uint256 id = _activePartnership();
        vm.prank(operator);
        desk.reportReturn(id, 40_000e6);

        vm.warp(reportingDeadline + 1);
        vm.prank(outsider);
        desk.declareDefault(id);

        uint256 before = usdc.balanceOf(funderOne);
        vm.prank(funderOne);
        desk.claim(id);
        assertEq(usdc.balanceOf(funderOne) - before, 20_000e6);
    }
}
