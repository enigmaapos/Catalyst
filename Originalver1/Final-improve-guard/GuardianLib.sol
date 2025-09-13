// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library GuardianLib {
    struct GuardianCouncil {
        address[] guardians;
        mapping(address => bool) isGuardian;
        uint256 threshold; // e.g. 5 of 7
    }

    struct Storage {
        GuardianCouncil deployerCouncil;
        GuardianCouncil adminCouncil;
    }

    // -------- Init --------
    function init(
        GuardianCouncil storage council,
        address[] memory _guardians,
        uint256 _threshold
    ) internal {
        require(_threshold > 0 && _threshold <= _guardians.length, "Invalid threshold");
        for (uint256 i = 0; i < _guardians.length; i++) {
            address g = _guardians[i];
            require(g != address(0), "Zero guardian");
            require(!council.isGuardian[g], "Duplicate guardian");
            council.guardians.push(g);
            council.isGuardian[g] = true;
        }
        council.threshold = _threshold;
    }

    // -------- Getters --------
    function isGuardian(GuardianCouncil storage council, address g) internal view returns (bool) {
        return council.isGuardian[g];
    }

    function guardianCount(GuardianCouncil storage council) internal view returns (uint256) {
        return council.guardians.length;
    }

    function getGuardians(GuardianCouncil storage council) internal view returns (address[] memory) {
        return council.guardians;
    }

    function thresholdMet(uint256 approvals, GuardianCouncil storage council) internal view returns (bool) {
        return approvals >= council.threshold;
    }
}
