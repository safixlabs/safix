// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

interface IPassportRegistry {
    function isEligible(address subject) external view returns (bool);
}
