// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @notice The brake. A guardian, separate from the owner, can stop new risk-taking in the block it
///         decides to; only the owner can start it again.
///
/// Actions are bits, so one transaction can stop several at once — a guardian reacting to a
/// compromised collateral token should not have to send three transactions and watch them land in
/// different blocks — while each action stays independently pausable for the narrower cases.
///
/// Pausing is deliberately asymmetric. Stopping is urgent and one signer's judgement is enough;
/// resuming is a considered decision and belongs to the owner, which becomes the multisig. A
/// guardian that could also unpause would be a second key with the owner's authority.
///
/// Nothing here can pause an exit. Which entry points are pausable at all is decided by each
/// contract, and no contract in this repository lets a user be trapped: repaying, closing a
/// position, claiming gains and withdrawing liquidity are never behind this switch.
abstract contract Guardable {
    /// @notice Set of actions currently stopped, as a bitmask of the contract's action constants.
    uint8 public pausedActions;

    /// @notice May pause, may not unpause.
    address public guardian;

    event GuardianSet(address indexed guardian);
    event Paused(uint8 actions, uint8 pausedAfter, address indexed by);
    event Unpaused(uint8 actions, uint8 pausedAfter, address indexed by);

    /// @notice Whether an action, or any action in a set, is currently stopped.
    function isPaused(uint8 actions) public view returns (bool) {
        return (pausedActions & actions) != 0;
    }

    function _setGuardian(address newGuardian) internal {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    function _pause(uint8 actions, address by) internal {
        require(actions != 0, "nothing to pause");
        pausedActions |= actions;
        emit Paused(actions, pausedActions, by);
    }

    function _unpause(uint8 actions, address by) internal {
        require(actions != 0, "nothing to unpause");
        pausedActions &= ~actions;
        emit Unpaused(actions, pausedActions, by);
    }
}
