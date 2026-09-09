// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @notice The reusable private collateral passport: five facts about a borrower, attested offchain
///         and carried onchain as bits, so an integrating platform can ask one question — is this
///         wallet eligible — without learning anything about the person behind it.
///
/// What is onchain is a bitmask and an expiry per bit. The evidence never is. That is the point: a
/// lender learns that identity was verified, not who the person is; that the jurisdiction is
/// permitted, not which one it is.
///
/// Each check expires on its own schedule, because the facts do not decay at the same rate. A
/// sanctions screen is stale in months; a verified identity is not. See docs/passport-policy.md for
/// the definitions, the expiry periods, and who attests.
contract PassportRegistry {
    /// @notice Identity verified against government-issued documents.
    uint8 public constant CHECK_IDENTITY = 1;
    /// @notice Resident of a permitted jurisdiction.
    uint8 public constant CHECK_JURISDICTION = 2;
    /// @notice Clear of sanctions, PEP and adverse media screening.
    uint8 public constant CHECK_SANCTIONS = 4;
    /// @notice Collateral is genuinely held and not pledged elsewhere.
    uint8 public constant CHECK_COLLATERAL = 8;
    /// @notice Existing debt leaves room to borrow.
    uint8 public constant CHECK_CAPACITY = 16;

    /// @notice All five. `isEligible` requires every one of them, unexpired.
    uint8 public constant FULL_MASK = 0x1f;

    struct Record {
        uint8 checkMask;
        /// @dev The earliest expiry across the checks that are set, so a reader wanting one number
        ///      gets the one that matters: when the passport first stops being complete.
        uint64 expiry;
    }

    address public owner;
    mapping(address => bool) public attesters;
    mapping(address => Record) public records;

    /// @notice When each individual check expires. Zero means it does not.
    mapping(address => mapping(uint8 => uint64)) public checkExpiry;

    event OwnerChanged(address indexed newOwner);
    event AttesterSet(address indexed attester, bool allowed);
    event Attested(address indexed subject, uint8 checkMask, uint64 expiry);
    event CheckAttested(address indexed subject, uint8 check, uint64 expiry);
    event CheckRevoked(address indexed subject, uint8 check);
    event Revoked(address indexed subject);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyAttester() {
        require(attesters[msg.sender] || msg.sender == owner, "not attester");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }

    function setAttester(address attester, bool allowed) external onlyOwner {
        attesters[attester] = allowed;
        emit AttesterSet(attester, allowed);
    }

    /// @dev Exactly one bit set, and a known one. Guards the per-check calls against a caller
    ///      passing a mask where a single check was meant.
    function _requireSingleCheck(uint8 check) private pure {
        require(check != 0 && check <= FULL_MASK && (check & (check - 1)) == 0, "not a single check");
    }

    /// @notice Records all five checks at once, with one expiry. The shape a first attestation
    ///         usually takes, when every check was performed in the same review.
    function attest(address subject, uint8 checkMask, uint64 expiry) external onlyAttester {
        require(checkMask <= FULL_MASK, "bad mask");
        Record storage record = records[subject];
        record.checkMask = checkMask;
        record.expiry = expiry;
        for (uint8 bit = 1; bit <= CHECK_CAPACITY; bit <<= 1) {
            checkExpiry[subject][bit] = (checkMask & bit) != 0 ? expiry : 0;
        }
        emit Attested(subject, checkMask, expiry);
    }

    /// @notice Records one check on its own schedule. This is the call used after the first
    ///         attestation: a sanctions screen is redone every quarter, an identity is not, and
    ///         renewing one should not silently extend the others.
    function attestCheck(address subject, uint8 check, uint64 expiry) external onlyAttester {
        _requireSingleCheck(check);
        Record storage record = records[subject];
        record.checkMask |= check;
        checkExpiry[subject][check] = expiry;
        record.expiry = _earliestExpiry(subject, record.checkMask);
        emit CheckAttested(subject, check, expiry);
    }

    /// @notice Withdraws one check, leaving the rest standing. The flow for a fact that changed:
    ///         somebody moved to a jurisdiction that is no longer permitted, or pledged their
    ///         collateral elsewhere. Their identity is still verified, and re-attesting the one
    ///         check that lapsed should not mean redoing the whole review.
    function revokeCheck(address subject, uint8 check) external onlyAttester {
        _requireSingleCheck(check);
        Record storage record = records[subject];
        record.checkMask &= ~check;
        checkExpiry[subject][check] = 0;
        record.expiry = _earliestExpiry(subject, record.checkMask);
        emit CheckRevoked(subject, check);
    }

    /// @notice Withdraws the passport entirely. For a subject who should no longer hold one at all,
    ///         rather than one whose circumstances changed.
    function revoke(address subject) external onlyAttester {
        delete records[subject];
        for (uint8 bit = 1; bit <= CHECK_CAPACITY; bit <<= 1) {
            checkExpiry[subject][bit] = 0;
        }
        emit Revoked(subject);
    }

    function _earliestExpiry(address subject, uint8 mask) private view returns (uint64 earliest) {
        for (uint8 bit = 1; bit <= CHECK_CAPACITY; bit <<= 1) {
            if ((mask & bit) == 0) continue;
            uint64 expiry = checkExpiry[subject][bit];
            if (expiry == 0) continue;
            if (earliest == 0 || expiry < earliest) earliest = expiry;
        }
    }

    /// @notice The mask and the earliest expiry across the checks that are set.
    function checkMaskOf(address subject) external view returns (uint8 checkMask, uint64 expiry) {
        Record storage record = records[subject];
        return (record.checkMask, record.expiry);
    }

    /// @notice Whether one check is currently held and unexpired.
    function hasCheck(address subject, uint8 check) public view returns (bool) {
        if ((records[subject].checkMask & check) == 0) return false;
        uint64 expiry = checkExpiry[subject][check];
        return expiry == 0 || expiry >= block.timestamp;
    }

    /// @notice The single question an integrating platform asks. Every check present, none expired.
    ///         Deliberately all-or-nothing: a partial passport is not a smaller permission, it is an
    ///         incomplete review, and a lender cannot tell which of the two it is looking at.
    function isEligible(address subject) external view returns (bool) {
        if (records[subject].checkMask != FULL_MASK) return false;
        for (uint8 bit = 1; bit <= CHECK_CAPACITY; bit <<= 1) {
            uint64 expiry = checkExpiry[subject][bit];
            if (expiry != 0 && expiry < block.timestamp) return false;
        }
        return true;
    }
}
