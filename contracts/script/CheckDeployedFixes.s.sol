// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {PartnershipDesk} from "../src/PartnershipDesk.sol";
import {MockAggregatorV3} from "../src/MockAggregatorV3.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Exercises four security fixes against a deployment's own bytecode (#34).
///
/// Simulation only: run it with `--rpc-url` and without `--broadcast`, and every call below executes
/// against the live contracts in a local copy of the chain's state that is thrown away afterwards.
/// Nothing is sent. Roles are impersonated with `vm.prank`, which a simulation allows and a chain
/// never would, so the script can ask the owner and the timelock to do things they would not do.
///
/// Each check prints PASS or FAIL, and the run reverts if any failed. Pointed at a deployment built
/// before the fixes it fails all four, which is what makes a PASS against the new one mean something.
///
/// The one test double is the feed in check 2. A round dated in the future is the failure being
/// tested, and no real feed reports one on demand.
///
/// Required environment: POOL, DESK. Everything else is read from the contracts.
contract CheckDeployedFixes is Script {
    SafixPool private pool;
    PartnershipDesk private desk;
    uint256 private failures;

    function run() external {
        pool = SafixPool(vm.envAddress("POOL"));
        desk = PartnershipDesk(vm.envAddress("DESK"));
        require(address(pool).code.length > 0 && address(desk).code.length > 0, "POOL or DESK has no code");
        console.log("pool", address(pool));
        console.log("desk", address(desk));

        _timelockCannotBeRepointedByTheOwner();
        _futureDatedRoundsReportRatherThanRevert();
        _returnedCapitalIsNotADefault();
        _anEmptyClaimIsNotSpent();

        console.log("");
        if (failures > 0) {
            console.log("FAILED", failures, "of 4");
            revert("a fix is not in the deployed bytecode");
        }
        console.log("all 4 fixes are in the deployed bytecode");
    }

    function _report(string memory name, bool passed, string memory detail) private {
        if (!passed) failures += 1;
        console.log(string.concat(passed ? "PASS  " : "FAIL  ", name, "  -- ", detail));
    }

    function _revertReason(bytes memory data) private pure returns (string memory) {
        if (data.length < 68) return data.length == 0 ? "(empty revert)" : "(undecodable revert)";
        bytes memory payload = new bytes(data.length - 4);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = data[i + 4];
        }
        return abi.decode(payload, (string));
    }

    // --------------------------------------------------------------------------------------
    // 1. setTimelock was onlyOwner: the owner could point the gate at itself
    // --------------------------------------------------------------------------------------

    function _timelockCannotBeRepointedByTheOwner() private {
        address poolOwner = pool.owner();
        vm.prank(poolOwner);
        (bool poolOk, bytes memory poolData) = address(pool).call(abi.encodeCall(SafixPool.setTimelock, (poolOwner)));

        address deskOwner = desk.owner();
        vm.prank(deskOwner);
        (bool deskOk, bytes memory deskData) =
            address(desk).call(abi.encodeCall(PartnershipDesk.setTimelock, (deskOwner)));

        bool passed = !poolOk && !deskOk && keccak256(poolData) == keccak256(deskData)
            && keccak256(bytes(_revertReason(poolData))) == keccak256("not timelock");
        _report(
            "1 setTimelock is behind the timelock",
            passed,
            string.concat(
                "owner -> pool.setTimelock(owner): ",
                poolOk ? "went through" : _revertReason(poolData),
                "; owner -> desk.setTimelock(owner): ",
                deskOk ? "went through" : _revertReason(deskData)
            )
        );
    }

    // --------------------------------------------------------------------------------------
    // 2. a future-dated oracle round underflowed both age checks
    // --------------------------------------------------------------------------------------

    function _futureDatedRoundsReportRatherThanRevert() private {
        address asset = pool.assetList(0);
        address someone = address(0xBEEF);

        // A price round dated a day ahead, wired the way a real feed swap is: through the timelock.
        MockAggregatorV3 priceFeed = new MockAggregatorV3(8);
        priceFeed.setAnswerAt(100e8, block.timestamp + 1 days);
        address gate = pool.timelock() == address(0) ? pool.owner() : pool.timelock();
        vm.prank(gate);
        pool.setPriceFeed(asset, address(priceFeed));
        (bool priceOk, bytes memory priceData) =
            address(pool).staticcall(abi.encodeCall(SafixPool.priceStatus, (asset)));
        uint256 priceStatus = priceOk ? uint256(abi.decode(priceData, (uint8))) : type(uint256).max;
        (bool liqOk,) = address(pool).staticcall(abi.encodeCall(SafixPool.isLiquidatable, (someone, asset)));

        // A sequencer round that started a day ahead, wired by the owner as the pool allows.
        MockAggregatorV3 sequencer = new MockAggregatorV3(0);
        sequencer.setRound(0, block.timestamp + 1 days, block.timestamp);
        vm.prank(pool.owner());
        pool.setSequencerUptimeFeed(address(sequencer), 1 hours);
        (bool seqOk, bytes memory seqData) = address(pool).staticcall(abi.encodeCall(SafixPool.priceStatus, (asset)));
        uint256 seqStatus = seqOk ? uint256(abi.decode(seqData, (uint8))) : type(uint256).max;

        bool passed = priceOk && priceStatus == uint256(SafixPool.PriceStatus.Stale) && liqOk && seqOk
            && seqStatus == uint256(SafixPool.PriceStatus.SequencerDown);
        _report(
            "2 future-dated rounds read as unusable instead of reverting",
            passed,
            string.concat(
                "price round +1 day: ",
                priceOk
                    ? string.concat("priceStatus ", vm.toString(priceStatus), " (5 = Stale)")
                    : "priceStatus reverted",
                liqOk ? ", isLiquidatable answers" : ", isLiquidatable reverted",
                "; sequencer round +1 day: ",
                seqOk
                    ? string.concat("priceStatus ", vm.toString(seqStatus), " (2 = SequencerDown)")
                    : "priceStatus reverted"
            )
        );
    }

    // --------------------------------------------------------------------------------------
    // 3 and 4. the desk
    // --------------------------------------------------------------------------------------

    /// @dev A fresh partnership on the live desk: `funded` from one funder, activated by the owner.
    function _activePartnership(address operator, address funder, uint256 funded) private returns (uint256 id) {
        MockERC20 stable = MockERC20(address(desk.stable()));
        vm.prank(desk.owner());
        id = desk.createPartnership(
            operator, 4000, funded, uint64(block.timestamp + 1 days), uint64(block.timestamp + 30 days)
        );
        stable.mint(funder, funded);
        vm.startPrank(funder);
        stable.approve(address(desk), funded);
        desk.fund(id, funded);
        vm.stopPrank();
        vm.prank(desk.owner());
        desk.activate(id);
        stable.mint(operator, funded * 2);
        vm.prank(operator);
        stable.approve(address(desk), type(uint256).max);
    }

    function _pastReportingDeadline(uint256 id) private {
        (,,,,,,,, uint64 reportingDeadline) = desk.partnerships(id);
        vm.warp(uint256(reportingDeadline) + 1);
    }

    function _returnedCapitalIsNotADefault() private {
        uint256 start = vm.snapshotState();
        address operator = address(0x0A11);
        uint256 id = _activePartnership(operator, address(0xF1), 10_000e6);

        // The operator returns everything, and the owner is slow to settle.
        vm.prank(operator);
        desk.reportReturn(id, 10_000e6);
        _pastReportingDeadline(id);

        vm.prank(address(0xD00D));
        (bool ok, bytes memory data) = address(desk).call(abi.encodeCall(PartnershipDesk.declareDefault, (id)));
        vm.revertToState(start);

        _report(
            "3 capital that came back cannot be declared a default",
            !ok && keccak256(bytes(_revertReason(data))) == keccak256("capital returned"),
            string.concat("full return, deadline passed, declareDefault: ", ok ? "went through" : _revertReason(data))
        );
    }

    function _anEmptyClaimIsNotSpent() private {
        uint256 start = vm.snapshotState();
        address operator = address(0x0A12);
        address funder = address(0xF2);
        uint256 id = _activePartnership(operator, funder, 10_000e6);
        MockERC20 stable = MockERC20(address(desk.stable()));

        // A silent operator, a default, and a funder who claims into it before anything came back.
        _pastReportingDeadline(id);
        desk.declareDefault(id);
        vm.prank(funder);
        desk.claim(id);
        bool spentByEmptyClaim = desk.claimed(id, funder);

        // The operator makes good afterwards; the funder must still be able to collect it.
        vm.prank(operator);
        desk.reportReturn(id, 10_000e6);
        uint256 before = stable.balanceOf(funder);
        vm.prank(funder);
        (bool ok, bytes memory data) = address(desk).call(abi.encodeCall(PartnershipDesk.claim, (id)));
        uint256 received = stable.balanceOf(funder) - before;
        vm.revertToState(start);

        _report(
            "4 a claim that paid nothing is not marked spent",
            !spentByEmptyClaim && ok && received == 10_000e6,
            string.concat(
                "empty claim marked spent: ",
                spentByEmptyClaim ? "yes" : "no",
                "; claim after the late return: ",
                ok ? string.concat("paid ", vm.toString(received)) : _revertReason(data)
            )
        );
    }
}
