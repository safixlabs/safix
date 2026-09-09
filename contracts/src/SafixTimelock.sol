// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @notice The delay between deciding to change a risk parameter and it taking effect.
///
/// A multisig can still be wrong, or captured. What a timelock buys is not a better decision but a
/// window: every change is visible onchain before it binds anyone, so a lender who disagrees with a
/// new LTV can leave before it applies to them. That is the whole product.
///
/// Only what changes user risk goes through here. Pausing does not — a brake that waits is not a
/// brake — and neither do the operational actions that cannot make a position worse. Which is
/// which is decided by the target contract, not by this one.
contract SafixTimelock {
    /// @notice Shortest delay this contract will accept. A timelock that can be shortened to nothing
    ///         in one transaction is decoration, so the floor is enforced here and the admin cannot
    ///         set anything under it, not even through the timelock itself.
    uint256 public constant MIN_DELAY = 1 days;

    /// @notice How long an operation stays executable once ready. Without a ceiling, a queued change
    ///         nobody remembers stays live forever and can be executed years later by anyone who
    ///         finds it.
    uint256 public constant GRACE_PERIOD = 14 days;

    /// @notice The multisig. Proposes, executes and cancels.
    address public admin;

    /// @notice Seconds between queueing and the earliest execution.
    uint256 public delay;

    /// @notice When each queued operation became eligible to be scheduled. Zero means not queued.
    mapping(bytes32 => uint256) public queuedAt;

    event AdminSet(address indexed admin);
    event DelaySet(uint256 delay);
    event Queued(bytes32 indexed id, address indexed target, bytes data, uint256 executableAt);
    event Executed(bytes32 indexed id, address indexed target, bytes data);
    event Cancelled(bytes32 indexed id);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    /// @dev Reachable only by this contract calling itself, which means through the delay.
    modifier onlySelf() {
        require(msg.sender == address(this), "not timelock");
        _;
    }

    constructor(address admin_, uint256 delay_) {
        require(admin_ != address(0), "zero admin");
        require(delay_ >= MIN_DELAY, "delay too short");
        admin = admin_;
        delay = delay_;
        emit AdminSet(admin_);
        emit DelaySet(delay_);
    }

    /// @notice Identifier for an operation. Salt lets the same call be queued more than once, and
    ///         lets two identical changes be distinguished when both are pending.
    function operationId(address target, bytes memory data, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(target, data, salt));
    }

    function isReady(bytes32 id) public view returns (bool) {
        uint256 queued = queuedAt[id];
        if (queued == 0) return false;
        return block.timestamp >= queued + delay && block.timestamp <= queued + delay + GRACE_PERIOD;
    }

    /// @notice Puts a call in the queue. The full calldata is in the event, so anyone watching the
    ///         chain can see exactly what was proposed, not merely that something was.
    function queue(address target, bytes calldata data, bytes32 salt) external onlyAdmin returns (bytes32 id) {
        require(target != address(0), "zero target");
        id = operationId(target, data, salt);
        require(queuedAt[id] == 0, "already queued");
        queuedAt[id] = block.timestamp;
        emit Queued(id, target, data, block.timestamp + delay);
    }

    /// @notice Runs a queued call once its delay has elapsed and before it goes stale.
    function execute(address target, bytes calldata data, bytes32 salt) external onlyAdmin returns (bytes memory) {
        bytes32 id = operationId(target, data, salt);
        uint256 queued = queuedAt[id];
        require(queued != 0, "not queued");
        require(block.timestamp >= queued + delay, "too early");
        require(block.timestamp <= queued + delay + GRACE_PERIOD, "expired");

        delete queuedAt[id];
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) {
            // Surface the target's own revert reason rather than a generic failure.
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        emit Executed(id, target, data);
        return result;
    }

    /// @notice Drops a queued operation. Cancelling is immediate: stopping a change is never the
    ///         thing that needs slowing down.
    function cancel(address target, bytes calldata data, bytes32 salt) external onlyAdmin {
        bytes32 id = operationId(target, data, salt);
        require(queuedAt[id] != 0, "not queued");
        delete queuedAt[id];
        emit Cancelled(id);
    }

    /// @notice Changes the delay. Goes through the delay itself, so shortening it is announced as
    ///         far in advance as any other change and cannot be used to rush one through.
    function setDelay(uint256 newDelay) external onlySelf {
        require(newDelay >= MIN_DELAY, "delay too short");
        delay = newDelay;
        emit DelaySet(newDelay);
    }

    /// @notice Hands the timelock to a new admin. Also goes through the delay: replacing the
    ///         multisig is the largest change there is.
    function setAdmin(address newAdmin) external onlySelf {
        require(newAdmin != address(0), "zero admin");
        admin = newAdmin;
        emit AdminSet(newAdmin);
    }
}
