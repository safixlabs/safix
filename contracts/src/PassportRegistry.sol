// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

contract PassportRegistry {
    uint8 public constant FULL_MASK = 0x1f;

    struct Record {
        uint8 checkMask;
        uint64 expiry;
    }

    address public owner;
    mapping(address => bool) public attesters;
    mapping(address => Record) public records;

    event OwnerChanged(address indexed newOwner);
    event AttesterSet(address indexed attester, bool allowed);
    event Attested(address indexed subject, uint8 checkMask, uint64 expiry);
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

    function attest(address subject, uint8 checkMask, uint64 expiry) external onlyAttester {
        require(checkMask <= FULL_MASK, "bad mask");
        records[subject] = Record({checkMask: checkMask, expiry: expiry});
        emit Attested(subject, checkMask, expiry);
    }

    function revoke(address subject) external onlyAttester {
        delete records[subject];
        emit Revoked(subject);
    }

    function checkMaskOf(address subject) external view returns (uint8 checkMask, uint64 expiry) {
        Record storage record = records[subject];
        return (record.checkMask, record.expiry);
    }

    function isEligible(address subject) external view returns (bool) {
        Record storage record = records[subject];
        if (record.checkMask != FULL_MASK) return false;
        return record.expiry == 0 || record.expiry >= block.timestamp;
    }
}
