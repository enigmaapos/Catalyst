// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GuardianLib.sol";

/// @title AdminCouncil (AGC)
/// @notice Protects DEFAULT_ADMIN_ROLE using guardian voting
contract AdminCouncil {
    using GuardianLib for GuardianLib.GuardianCouncil;

    address public admin;
    GuardianLib.GuardianCouncil private council;

    constructor(address initAdmin, address[] calldata guardians) {
        admin = initAdmin;
        council.init(guardians, 5, 3 days); // 5-of-7
    }

    function proposeAdminRecovery(address newAdmin) external {
        council.proposeRecovery(newAdmin);
    }

    function approveAdminRecovery() external {
        council.approveRecovery();
    }

    function executeAdminRecovery() external {
        if (!council.canExecute()) revert GuardianLib.RecoveryNotMet();
        address old = admin;
        admin = council.active.proposed;
        council.markExecuted();
        emit GuardianLib.RecoveryExecuted(old, admin);
    }

    function guardians() external view returns (address[] memory) {
        return council.guardians();
    }
}
