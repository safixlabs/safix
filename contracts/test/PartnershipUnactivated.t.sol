// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PartnershipDesk} from "../src/PartnershipDesk.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice What happens when the owner goes quiet before activation (#32).
///
/// `declareDefault` gives funders a way out when the operator goes silent. A partnership that was
/// funded but never activated had no equivalent: `activate` and `cancel` are both the owner's, and
/// `claim` needs the partnership settled, cancelled or defaulted. Once the funding deadline has
/// passed without an activation, anyone may now move it to Cancelled, and the existing claim returns
/// each contribution in full. The owner keeps the choice of whether to activate.
contract PartnershipUnactivatedTest is Test {
    PartnershipDesk internal desk;
    MockERC20 internal usdc;

    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");
    address internal funderOne = makeAddr("funderOne");
    address internal funderTwo = makeAddr("funderTwo");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant STARTING_BALANCE = 1_000_000e6;

    uint64 internal fundingDeadline;
    uint64 internal reportingDeadline;

    function setUp() public {
        vm.warp(1_000 days);
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        desk = new PartnershipDesk(address(usdc));
        desk.setGuardian(guardian);

        fundingDeadline = uint64(block.timestamp + 14 days);
        reportingDeadline = uint64(block.timestamp + 180 days);

        address[2] memory funders = [funderOne, funderTwo];
        for (uint256 i = 0; i < funders.length; i++) {
            usdc.mint(funders[i], STARTING_BALANCE);
            vm.prank(funders[i]);
            usdc.approve(address(desk), type(uint256).max);
        }
    }

    /// @dev The issue's reproduction: a 100,000 goal, one funder in at 10,000, goal not reached,
    ///      and an owner who never activates and never cancels.
    function _fundedButNeverActivated() internal returns (uint256 id) {
        id = desk.createPartnership(operator, 4000, 100_000e6, fundingDeadline, reportingDeadline);
        vm.prank(funderOne);
        desk.fund(id, 10_000e6);
    }

    function _status(uint256 id) internal view returns (PartnershipDesk.Status status) {
        (,,, status,,,,,) = desk.partnerships(id);
    }

    // --------------------------------------------------------------------------------------
    // the silent owner
    // --------------------------------------------------------------------------------------

    function testFundersRecoverWhenTheOwnerNeverActivates() public {
        uint256 id = _fundedButNeverActivated();
        vm.warp(fundingDeadline + 1);

        // Every other door is shut: nothing is claimable yet, there is no default without an
        // activation, and cancelling is the owner's.
        vm.startPrank(funderOne);
        vm.expectRevert(bytes("not claimable"));
        desk.claim(id);
        vm.expectRevert(bytes("not active"));
        desk.declareDefault(id);
        vm.expectRevert(bytes("not owner"));
        desk.cancel(id);
        vm.stopPrank();

        // Anyone may open the one that is left. It is the same Cancelled the owner's cancel emits,
        // so the index and the app read it without knowing which path produced it.
        vm.expectEmit(true, false, false, false, address(desk));
        emit PartnershipDesk.Cancelled(id);
        vm.prank(outsider);
        desk.cancelUnactivated(id);

        uint256 before = usdc.balanceOf(funderOne);
        vm.prank(funderOne);
        desk.claim(id);
        assertEq(usdc.balanceOf(funderOne) - before, 10_000e6, "the whole contribution came back");
        assertEq(usdc.balanceOf(address(desk)), 0);
    }

    function testTheExitOpensTheSecondAfterTheFundingDeadline() public {
        uint256 id = _fundedButNeverActivated();

        // On the deadline itself funding is still open, so the partnership is still being funded.
        vm.warp(fundingDeadline);
        vm.prank(funderTwo);
        desk.fund(id, 1_000e6);
        vm.prank(outsider);
        vm.expectRevert(bytes("before deadline"));
        desk.cancelUnactivated(id);

        // One second later funding has closed, and the exit opens.
        vm.warp(fundingDeadline + 1);
        vm.prank(funderTwo);
        vm.expectRevert(bytes("past deadline"));
        desk.fund(id, 1_000e6);
        vm.prank(outsider);
        desk.cancelUnactivated(id);
        assertEq(uint8(_status(id)), uint8(PartnershipDesk.Status.Cancelled));
    }

    // --------------------------------------------------------------------------------------
    // what the owner keeps
    // --------------------------------------------------------------------------------------

    function testTheOwnerKeepsTheChoiceToActivateUntilSomeoneCancels() public {
        uint256 id = _fundedButNeverActivated();
        vm.warp(fundingDeadline + 1);
        uint256 afterTheDeadline = vm.snapshotState();

        // Nobody has cancelled, so the owner can still go ahead: the exit removes the ability to
        // strand capital by doing nothing, not the choice itself.
        desk.activate(id);
        assertEq(usdc.balanceOf(operator), 10_000e6);
        assertEq(uint8(_status(id)), uint8(PartnershipDesk.Status.Active));

        // Once a funder has declined to wait any longer, the partnership is over. Whichever
        // transaction lands first decides, and either way the funders have a way out: a refund
        // here, the reporting deadline there.
        vm.revertToState(afterTheDeadline);
        vm.prank(funderOne);
        desk.cancelUnactivated(id);
        vm.expectRevert(bytes("not funding"));
        desk.activate(id);
    }

    // --------------------------------------------------------------------------------------
    // what the exit refuses
    // --------------------------------------------------------------------------------------

    function testAnActivatedPartnershipIsNotCancelledThisWay() public {
        uint256 id = _fundedButNeverActivated();
        desk.activate(id);
        vm.warp(fundingDeadline + 1);

        // Capital already with the operator is recovered through the reporting deadline instead.
        vm.prank(outsider);
        vm.expectRevert(bytes("not funding"));
        desk.cancelUnactivated(id);
        vm.prank(outsider);
        vm.expectRevert(bytes("before deadline"));
        desk.declareDefault(id);
    }

    function testOnlyAPartnershipThatExistsCanBeCancelled() public {
        // An id nobody has created reads as an empty struct: status Funding, deadline zero. Without
        // a check, anyone could mark it Cancelled and put a Cancelled event on record for a
        // partnership that never existed.
        uint256 next = desk.partnershipCount();
        vm.prank(outsider);
        vm.expectRevert(bytes("no partnership"));
        desk.cancelUnactivated(next);
    }

    // --------------------------------------------------------------------------------------
    // what it pays
    // --------------------------------------------------------------------------------------

    function testTheExitStaysOpenWhileFundingIsPaused() public {
        uint256 id = _fundedButNeverActivated();
        uint8 all = desk.PAUSE_ALL();
        vm.prank(guardian);
        desk.pause(all);
        vm.warp(fundingDeadline + 1);

        // A pause stops new capital going in. It never keeps capital from coming out.
        vm.prank(funderOne);
        desk.cancelUnactivated(id);
        vm.prank(funderOne);
        desk.claim(id);
        assertEq(usdc.balanceOf(funderOne), STARTING_BALANCE);
    }

    function testEveryFunderGetsExactlyTheirContributionBack() public {
        uint256 id = _fundedButNeverActivated();
        vm.prank(funderTwo);
        desk.fund(id, 25_000e6);
        vm.warp(fundingDeadline + 1);
        vm.prank(outsider);
        desk.cancelUnactivated(id);

        vm.prank(funderOne);
        desk.claim(id);
        vm.prank(funderTwo);
        desk.claim(id);
        assertEq(usdc.balanceOf(funderOne), STARTING_BALANCE);
        assertEq(usdc.balanceOf(funderTwo), STARTING_BALANCE);
        assertEq(usdc.balanceOf(address(desk)), 0, "nothing left behind");

        // A one-way door, once.
        vm.prank(outsider);
        vm.expectRevert(bytes("not funding"));
        desk.cancelUnactivated(id);
        vm.prank(funderOne);
        vm.expectRevert(bytes("nothing to claim"));
        desk.claim(id);
    }
}
