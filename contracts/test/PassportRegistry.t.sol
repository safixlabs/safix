// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PassportRegistry} from "../src/PassportRegistry.sol";

contract PassportRegistryTest is Test {
    PassportRegistry internal registry;

    address internal attester = makeAddr("attester");
    address internal subject = makeAddr("subject");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        registry = new PassportRegistry();
        registry.setAttester(attester, true);
    }

    function testAttestAndEligibility() public {
        assertFalse(registry.isEligible(subject));

        vm.prank(attester);
        registry.attest(subject, 0x1f, 0);
        assertTrue(registry.isEligible(subject));

        (uint8 mask, uint64 expiry) = registry.checkMaskOf(subject);
        assertEq(mask, 0x1f);
        assertEq(expiry, 0);
    }

    function testPartialMaskIsNotEligible() public {
        vm.prank(attester);
        registry.attest(subject, 0x1b, 0);
        assertFalse(registry.isEligible(subject));
    }

    function testExpiryEndsEligibility() public {
        vm.prank(attester);
        registry.attest(subject, 0x1f, uint64(block.timestamp + 1 days));
        assertTrue(registry.isEligible(subject));

        vm.warp(block.timestamp + 2 days);
        assertFalse(registry.isEligible(subject));
    }

    function testRevoke() public {
        vm.prank(attester);
        registry.attest(subject, 0x1f, 0);
        vm.prank(attester);
        registry.revoke(subject);
        assertFalse(registry.isEligible(subject));
    }

    function testGuards() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not attester"));
        registry.attest(subject, 0x1f, 0);

        vm.prank(attester);
        vm.expectRevert(bytes("bad mask"));
        registry.attest(subject, 0x3f, 0);

        vm.prank(stranger);
        vm.expectRevert(bytes("not owner"));
        registry.setAttester(stranger, true);
    }
}
