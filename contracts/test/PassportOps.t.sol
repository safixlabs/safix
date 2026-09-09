// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PassportRegistry} from "../src/PassportRegistry.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice The passport as an operation rather than a data structure: one check renewed without
///         touching the others, one withdrawn when a fact changes, and the gate on the pool
///         responding to both.
contract PassportOpsTest is Test {
    PassportRegistry internal registry;
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal tbill;

    address internal attester = makeAddr("attester");
    address internal outsider = makeAddr("outsider");
    address internal provider = makeAddr("provider");
    address internal borrower = makeAddr("borrower");

    uint8 internal constant IDENTITY = 1;
    uint8 internal constant JURISDICTION = 2;
    uint8 internal constant SANCTIONS = 4;
    uint8 internal constant COLLATERAL = 8;
    uint8 internal constant CAPACITY = 16;
    uint8 internal constant ALL = 0x1f;

    function setUp() public {
        vm.warp(1_000 days);
        registry = new PassportRegistry();
        registry.setAttester(attester, true);

        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);
        pool.setPassportRegistry(address(registry));

        usdc.mint(provider, 1_000_000e6);
        usdc.mint(borrower, 10_000e6);
        tbill.mint(borrower, 1_000e18);
        vm.prank(provider);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(provider);
        pool.deposit(100_000e6);
        vm.startPrank(borrower);
        tbill.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.lockCollateral(address(tbill), 100e18);
        vm.stopPrank();
    }

    function _draw(uint256 amount) internal {
        vm.prank(borrower);
        pool.draw(address(tbill), amount);
    }

    // --- the acceptance path, end to end -------------------------------------------------

    function testAttestedUserBorrowsThenIsRevokedAndBlocked() public {
        vm.prank(borrower);
        vm.expectRevert(bytes("passport required"));
        pool.draw(address(tbill), 1_000e6);

        vm.prank(attester);
        registry.attest(borrower, ALL, uint64(block.timestamp + 365 days));
        assertTrue(registry.isEligible(borrower));
        _draw(1_000e6);

        vm.prank(attester);
        registry.revoke(borrower);
        assertFalse(registry.isEligible(borrower));

        vm.prank(borrower);
        vm.expectRevert(bytes("passport required"));
        pool.draw(address(tbill), 100e6);

        // Revoking a passport never traps the position it was used to open.
        vm.startPrank(borrower);
        pool.repay(address(tbill), 500e6);
        pool.closePosition(address(tbill));
        vm.stopPrank();
        assertEq(tbill.balanceOf(borrower), 1_000e18, "collateral came back in full");
    }

    // --- one check at a time ---------------------------------------------------------------

    function testRenewingOneCheckDoesNotExtendTheOthers() public {
        uint64 shortLived = uint64(block.timestamp + 90 days);
        uint64 longLived = uint64(block.timestamp + 365 days);

        vm.startPrank(attester);
        registry.attest(borrower, ALL, longLived);
        // The sanctions screen is redone on a shorter cycle than the rest.
        registry.attestCheck(borrower, SANCTIONS, shortLived);
        vm.stopPrank();

        assertEq(registry.checkExpiry(borrower, SANCTIONS), shortLived);
        assertEq(registry.checkExpiry(borrower, IDENTITY), longLived);
        (, uint64 earliest) = registry.checkMaskOf(borrower);
        assertEq(earliest, shortLived, "the summary expiry is the first one to lapse");
    }

    function testAnExpiredCheckAloneEndsEligibility() public {
        vm.startPrank(attester);
        registry.attest(borrower, ALL, uint64(block.timestamp + 365 days));
        registry.attestCheck(borrower, SANCTIONS, uint64(block.timestamp + 90 days));
        vm.stopPrank();

        assertTrue(registry.isEligible(borrower));
        _draw(1_000e6);

        vm.warp(block.timestamp + 91 days);
        assertFalse(registry.isEligible(borrower), "one lapsed check ends the passport");
        assertFalse(registry.hasCheck(borrower, SANCTIONS));
        assertTrue(registry.hasCheck(borrower, IDENTITY), "the others are untouched");

        vm.prank(borrower);
        vm.expectRevert(bytes("passport required"));
        pool.draw(address(tbill), 100e6);

        // Re-screening restores it without redoing the whole review.
        vm.prank(attester);
        registry.attestCheck(borrower, SANCTIONS, uint64(block.timestamp + 90 days));
        assertTrue(registry.isEligible(borrower));
        _draw(100e6);
    }

    function testWithdrawingOneCheckLeavesTheRestStanding() public {
        vm.prank(attester);
        registry.attest(borrower, ALL, 0);
        assertTrue(registry.isEligible(borrower));

        // A fact changed: they moved somewhere that is no longer permitted.
        vm.prank(attester);
        registry.revokeCheck(borrower, JURISDICTION);

        assertFalse(registry.isEligible(borrower));
        assertFalse(registry.hasCheck(borrower, JURISDICTION));
        assertTrue(registry.hasCheck(borrower, IDENTITY), "identity did not stop being verified");
        (uint8 mask,) = registry.checkMaskOf(borrower);
        assertEq(mask, ALL & ~JURISDICTION);

        vm.prank(borrower);
        vm.expectRevert(bytes("passport required"));
        pool.draw(address(tbill), 100e6);
    }

    function testEveryCheckIsRequired() public {
        // Any one of the five missing means no passport: a partial one is an incomplete review,
        // not a smaller permission.
        for (uint8 bit = 1; bit <= CAPACITY; bit <<= 1) {
            vm.prank(attester);
            registry.attest(borrower, ALL & ~bit, 0);
            assertFalse(registry.isEligible(borrower));
        }
        vm.prank(attester);
        registry.attest(borrower, ALL, 0);
        assertTrue(registry.isEligible(borrower));
    }

    // --- who may attest ---------------------------------------------------------------------

    function testOnlyAnAttesterWrites() public {
        vm.startPrank(outsider);
        vm.expectRevert(bytes("not attester"));
        registry.attest(borrower, ALL, 0);
        vm.expectRevert(bytes("not attester"));
        registry.attestCheck(borrower, IDENTITY, 0);
        vm.expectRevert(bytes("not attester"));
        registry.revokeCheck(borrower, IDENTITY);
        vm.expectRevert(bytes("not attester"));
        registry.revoke(borrower);
        vm.stopPrank();

        vm.expectRevert(bytes("not owner"));
        vm.prank(outsider);
        registry.setAttester(outsider, true);
    }

    function testAnAttesterCanBeStoodDown() public {
        registry.setAttester(attester, false);
        vm.prank(attester);
        vm.expectRevert(bytes("not attester"));
        registry.attest(borrower, ALL, 0);
    }

    function testAMaskWhereASingleCheckWasMeantIsRefused() public {
        vm.startPrank(attester);
        vm.expectRevert(bytes("not a single check"));
        registry.attestCheck(borrower, IDENTITY | SANCTIONS, 0);
        vm.expectRevert(bytes("not a single check"));
        registry.attestCheck(borrower, 0, 0);
        vm.expectRevert(bytes("not a single check"));
        registry.revokeCheck(borrower, ALL);
        vm.stopPrank();
    }

    function testABadMaskIsRefused() public {
        vm.prank(attester);
        vm.expectRevert(bytes("bad mask"));
        registry.attest(borrower, 0x20, 0);
    }

    function testRevokingClearsEveryPerCheckExpiry() public {
        vm.startPrank(attester);
        registry.attest(borrower, ALL, uint64(block.timestamp + 100 days));
        registry.revoke(borrower);
        vm.stopPrank();
        for (uint8 bit = 1; bit <= CAPACITY; bit <<= 1) {
            assertEq(registry.checkExpiry(borrower, bit), 0, "a stale expiry must not survive a revoke");
        }
    }

    // --- the gate itself --------------------------------------------------------------------

    function testTheGateIsOffWhenNoRegistryIsSet() public {
        SafixPool ungated = new SafixPool(address(usdc));
        ungated.configureAsset(address(tbill), 8000, 9000, 100e18);
        assertEq(ungated.passportRegistry(), address(0));

        vm.prank(provider);
        usdc.approve(address(ungated), type(uint256).max);
        vm.prank(provider);
        ungated.deposit(50_000e6);
        vm.startPrank(borrower);
        tbill.approve(address(ungated), type(uint256).max);
        ungated.lockCollateral(address(tbill), 100e18);
        ungated.draw(address(tbill), 1_000e6);
        vm.stopPrank();
    }

    function testTheGateOnlyGuardsDrawing() public {
        // No passport at all: everything except drawing still works, so an ineligible wallet is
        // never left holding collateral it cannot retrieve.
        assertFalse(registry.isEligible(borrower));
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), 100e18);
        pool.withdrawCollateral(address(tbill), 50e18);
        vm.stopPrank();
        vm.prank(provider);
        pool.deposit(1_000e6);
        vm.prank(provider);
        pool.withdraw(1_000e6);
    }
}
