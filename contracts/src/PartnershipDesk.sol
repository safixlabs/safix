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
        Cancelled
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
    }

    uint256 private constant BPS = 10_000;

    IERC20 public immutable stable;
    address public owner;
    address public auditor;
    uint256 public partnershipCount;
    mapping(uint256 => bool) public settlementApproved;

    mapping(uint256 => Partnership) public partnerships;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(uint256 => mapping(address => bool)) public claimed;

    bool private entered;

    event OwnerChanged(address indexed newOwner);
    event AuditorSet(address indexed auditor);
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
    event FunderClaimed(uint256 indexed id, address indexed funder, uint256 amount);
    event OperatorClaimed(uint256 indexed id, address indexed operator, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
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

    function setAuditor(address auditor_) external onlyOwner {
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
        uint64 fundingDeadline
    ) external onlyOwner returns (uint256 id) {
        require(operator != address(0), "no operator");
        require(operatorShareBps <= BPS, "bad share");
        require(fundingGoal > 0, "no goal");
        id = partnershipCount++;
        partnerships[id] = Partnership({
            operator: operator,
            operatorShareBps: operatorShareBps,
            fundingDeadline: fundingDeadline,
            status: Status.Funding,
            fundingGoal: fundingGoal,
            funded: 0,
            returned: 0,
            operatorPaid: false
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
        require(partnership.status == Status.Active, "not active");
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
        if (partnership.status != Status.Settled || partnership.funded == 0) return 0;
        uint256 funderPool = partnership.returned - operatorShareOf(id);
        return (funderPool * contribution) / partnership.funded;
    }

    function claim(uint256 id) external nonReentrant {
        uint256 payout = funderPayoutOf(id, msg.sender);
        require(
            partnerships[id].status == Status.Settled || partnerships[id].status == Status.Cancelled,
            "not claimable"
        );
        require(contributions[id][msg.sender] > 0 && !claimed[id][msg.sender], "nothing to claim");
        claimed[id][msg.sender] = true;
        if (payout > 0) {
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
