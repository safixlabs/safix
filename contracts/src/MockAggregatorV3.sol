// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @notice Test double for a Chainlink AggregatorV3 feed. Keeps a round history so consumers that
///         compare consecutive rounds can be exercised, and can be made to revert on demand so the
///         "feed is unreachable" path is reachable from a test.
///
/// It also stands in for an L2 sequencer uptime feed, where the convention is answer 0 for up and
/// 1 for down, and startedAt is when that status last changed.
contract MockAggregatorV3 {
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    uint8 public immutable decimals;
    bool public reverting;
    /// @dev A feed that answers for the latest round and not for older ones. Real aggregators
    ///      behave this way after an upgrade: history moves to the new aggregator's numbering and
    ///      the round before the current one stops resolving, while the latest answer is fine.
    bool public revertingHistory;
    uint80 public latestRound;

    mapping(uint80 => Round) public rounds;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    /// @dev Latest answer, kept for readers that only want the number.
    function answer() external view returns (int256) {
        return rounds[latestRound].answer;
    }

    function updatedAt() external view returns (uint256) {
        return rounds[latestRound].updatedAt;
    }

    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }

    function setRevertingHistory(bool revertingHistory_) external {
        revertingHistory = revertingHistory_;
    }

    /// @dev Publishes a new round stamped with the current block time.
    function setAnswer(int256 answer_) external {
        _push(answer_, block.timestamp, block.timestamp);
    }

    /// @dev Publishes a new round with an explicit updatedAt, for staleness tests.
    function setAnswerAt(int256 answer_, uint256 updatedAt_) external {
        _push(answer_, updatedAt_, updatedAt_);
    }

    /// @dev Full control over a round, for sequencer status changes where startedAt is what matters.
    function setRound(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        _push(answer_, startedAt_, updatedAt_);
    }

    /// @dev Overwrites the latest round in place, so a jump can be created without a prior round.
    function overwriteLatest(int256 answer_) external {
        rounds[latestRound] = Round({answer: answer_, startedAt: block.timestamp, updatedAt: block.timestamp});
    }

    function _push(int256 answer_, uint256 startedAt_, uint256 updatedAt_) internal {
        latestRound += 1;
        rounds[latestRound] = Round({answer: answer_, startedAt: startedAt_, updatedAt: updatedAt_});
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting) revert("feed down");
        Round storage round = rounds[latestRound];
        return (latestRound, round.answer, round.startedAt, round.updatedAt, latestRound);
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting || revertingHistory) revert("feed down");
        Round storage round = rounds[roundId];
        return (roundId, round.answer, round.startedAt, round.updatedAt, roundId);
    }
}
