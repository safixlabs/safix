// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Guardable} from "./Guardable.sol";
import {IERC20} from "./interfaces/IERC20.sol";

contract PartnershipDesk is Guardable {
    /// @notice Only funding is pausable: it is the one action that puts new capital at risk.
    /// Reporting a return, settling, and both claims stay open in every state, so a funder is
    /// never left unable to collect and an operator is never unable to pay back.
    uint8 public constant PAUSE_FUNDING = 1;
    uint8 public constant PAUSE_ALL = 1;

    enum Status {
        Funding,
        Active,
        Settled,
        Cancelled,
        /// @notice The operator went past the reporting deadline without settling. Funders recover
        ///         whatever was returned; the operator's profit share is forfeit.
        Defaulted
    }

    struct Partnership {
        address operator;
        uint16 operatorShareBps;
        uint64 fundingDeadline;
        Status status;
        uint256 fundingGoal;
        uint256 funded;
        uint256 returned;
        bool operatorPaid;
        /// @dev Latest the partnership may be settled by. Appended after the original fields, so a
        ///      reader built against the older shape still decodes those correctly.
        uint64 reportingDeadline;
    }

    uint256 private constant BPS = 10_000;

    IERC20 public immutable stable;
    address public owner;

    /// @notice Holds the delay on the auditor mandate. Zero means none is wired yet.
    address public timelock;

    address public auditor;
    uint256 public partnershipCount;
    mapping(uint256 => bool) public settlementApproved;

    mapping(uint256 => Partnership) public partnerships;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(uint256 => mapping(address => bool)) public claimed;

    bool private entered;

    event OwnerChanged(address indexed newOwner);
    event AuditorSet(address indexed auditor);
    event TimelockSet(address indexed timelock);
    event SettlementApproved(uint256 indexed id, address indexed auditor);
    event PartnershipCreated(
        uint256 indexed id,
        address indexed operator,
        uint16 operatorShareBps,
        uint256 fundingGoal,
        uint64 fundingDeadline
    );
    event Funded(uint256 indexed id, address indexed funder, uint256 amount);
    event Activated(uint256 indexed id, uint256 funded);
    event Cancelled(uint256 indexed id);
    event ReturnReported(uint256 indexed id, uint256 amount, uint256 totalReturned);
    event Settled(uint256 indexed id);
    event Defaulted(uint256 indexed id, uint256 returned);
    event FunderClaimed(uint256 indexed id, address indexed funder, uint256 amount);
    event OperatorClaimed(uint256 indexed id, address indexed operator, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyTimelock() {
        require(msg.sender == (timelock == address(0) ? owner : timelock), "not timelock");
        _;
    }

    modifier nonReentrant() {
        require(!entered, "reentrancy");
        entered = true;
        _;
        entered = false;
    }

    constructor(address stable_) {
        stable = IERC20(stable_);
        owner = msg.sender;
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }

    /// @notice Wires the timelock. The desk's auditor is the setting that changes what a funder is
    ///         exposed to, so it moves behind the delay once one is set.
    function setTimelock(address newTimelock) external onlyTimelock {
        timelock = newTimelock;
        emit TimelockSet(newTimelock);
    }

    /// @notice Appoints the guardian, separate from the owner.
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }

    /// @notice Stops new funding immediately, with no timelock.
    function pause(uint8 actions) external {
        require(msg.sender == guardian || msg.sender == owner, "not guardian");
        _pause(actions, msg.sender);
    }

    /// @notice Resumes funding. Owner only, never the guardian alone.
    function unpause(uint8 actions) external onlyOwner {
        _unpause(actions, msg.sender);
    }

    function setAuditor(address auditor_) external onlyTimelock {
        auditor = auditor_;
        emit AuditorSet(auditor_);
    }

    function approveSettlement(uint256 id) external {
        require(msg.sender == auditor, "not auditor");
        require(partnerships[id].status == Status.Active, "not active");
        settlementApproved[id] = true;
        emit SettlementApproved(id, msg.sender);
    }

    function createPartnership(
        address operator,
        uint16 operatorShareBps,
        uint256 fundingGoal,
        uint64 fundingDeadline,
        uint64 reportingDeadline
    ) external onlyOwner returns (uint256 id) {
        require(operator != address(0), "no operator");
        require(operatorShareBps <= BPS, "bad share");
        require(fundingGoal > 0, "no goal");
        // Capital that goes out has to have a date by which it comes back, or a silent operator
        // leaves the funders with no way to recover anything at all.
        require(reportingDeadline > fundingDeadline, "reporting before funding ends");
        id = partnershipCount++;
        partnerships[id] = Partnership({
            operator: operator,
            operatorShareBps: operatorShareBps,
            fundingDeadline: fundingDeadline,
            status: Status.Funding,
            fundingGoal: fundingGoal,
            funded: 0,
            returned: 0,
            operatorPaid: false,
            reportingDeadline: reportingDeadline
        });
        emit PartnershipCreated(id, operator, operatorShareBps, fundingGoal, fundingDeadline);
    }

    function fund(uint256 id, uint256 amount) external nonReentrant {
        require(!isPaused(PAUSE_FUNDING), "funding paused");
        Partnership storage partnership = partnerships[id];
        require(partnership.status == Status.Funding, "not funding");
        require(block.timestamp <= partnership.fundingDeadline, "past deadline");
        require(amount > 0 && partnership.funded + amount <= partnership.fundingGoal, "bad amount");
        partnership.funded += amount;
        contributions[id][msg.sender] += amount;
        require(stable.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Funded(id, msg.sender, amount);
    }

    function activate(uint256 id) external onlyOwner nonReentrant {
        Partnership storage partnership = partnerships[id];
        require(partnership.status == Status.Funding, "not funding");
        require(partnership.funded > 0, "unfunded");
        partnership.status = Status.Active;
        require(stable.transfer(partnership.operator, partnership.funded), "transfer failed");
        emit Activated(id, partnership.funded);
    }

    function cancel(uint256 id) external onlyOwner {
        Partnership storage partnership = partnerships[id];
        require(partnership.status == Status.Funding, "not funding");
        partnership.status = Status.Cancelled;
        emit Cancelled(id);
    }

    function reportReturn(uint256 id, uint256 amount) external nonReentrant {
        Partnership storage partnership = partnerships[id];
        // Still open after a default: an operator making good afterwards is strictly better for the
        // funders than one who stops because the door closed.
        require(
            partnership.status == Status.Active || partnership.status == Status.Defaulted,
            "not active"
        );
        require(msg.sender == partnership.operator, "not operator");
        require(amount > 0, "zero");
        partnership.returned += amount;
        require(stable.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit ReturnReported(id, amount, partnership.returned);
    }

    function settle(uint256 id) external onlyOwner {
        Partnership storage partnership = partnerships[id];
        require(partnership.status == Status.Active, "not active");
        if (auditor != address(0)) {
            require(settlementApproved[id], "needs audit");
        }
        partnership.status = Status.Settled;
        emit Settled(id);
    }

    /// @notice Marks a partnership defaulted once its reporting deadline has passed without a
    ///         settlement. Callable by anyone: the funders' recovery must not depend on the owner
    ///         being available, and the condition is a date that either has passed or has not.
    ///
    /// Whatever the operator returned is distributed to funders pro rata. The operator's profit
    /// share is forfeit — a partnership that had to be declared in default did not earn one.
    function declareDefault(uint256 id) external {
        Partnership storage partnership = partnerships[id];
        require(partnership.status == Status.Active, "not active");
        require(block.timestamp > partnership.reportingDeadline, "before deadline");
        // Capital that came back is not a default, however slow the settlement is.
        require(partnership.returned < partnership.funded, "capital returned");
        partnership.status = Status.Defaulted;
        emit Defaulted(id, partnership.returned);
    }

    function profitOf(uint256 id) public view returns (uint256) {
        Partnership storage partnership = partnerships[id];
        return partnership.returned > partnership.funded ? partnership.returned - partnership.funded : 0;
    }

    function operatorShareOf(uint256 id) public view returns (uint256) {
        Partnership storage partnership = partnerships[id];
        return (profitOf(id) * partnership.operatorShareBps) / BPS;
    }

    function funderPayoutOf(uint256 id, address funder) public view returns (uint256) {
        Partnership storage partnership = partnerships[id];
        uint256 contribution = contributions[id][funder];
        if (contribution == 0 || claimed[id][funder]) return 0;
        if (partnership.status == Status.Cancelled) return contribution;
        if (partnership.funded == 0) return 0;
        if (partnership.status == Status.Defaulted) {
            // No operator share: everything recovered goes back to the funders.
            return (partnership.returned * contribution) / partnership.funded;
        }
        if (partnership.status != Status.Settled) return 0;
        uint256 funderPool = partnership.returned - operatorShareOf(id);
        return (funderPool * contribution) / partnership.funded;
    }

    function claim(uint256 id) external nonReentrant {
        uint256 payout = funderPayoutOf(id, msg.sender);
        Status status = partnerships[id].status;
        require(
            status == Status.Settled || status == Status.Cancelled || status == Status.Defaulted,
            "not claimable"
        );
        require(contributions[id][msg.sender] > 0 && !claimed[id][msg.sender], "nothing to claim");
        // Only a claim that pays is spent. An operator can still make good after a default, so a
        // funder who asked while there was nothing to take must not be locked out of what arrives.
        if (payout > 0) {
            claimed[id][msg.sender] = true;
            require(stable.transfer(msg.sender, payout), "transfer failed");
        }
        emit FunderClaimed(id, msg.sender, payout);
    }

    function claimOperator(uint256 id) external nonReentrant {
        Partnership storage partnership = partnerships[id];
        require(partnership.status == Status.Settled, "not settled");
        require(msg.sender == partnership.operator, "not operator");
        require(!partnership.operatorPaid, "paid");
        partnership.operatorPaid = true;
        uint256 amount = operatorShareOf(id);
        if (amount > 0) {
            require(stable.transfer(partnership.operator, amount), "transfer failed");
        }
        emit OperatorClaimed(id, partnership.operator, amount);
    }
}
