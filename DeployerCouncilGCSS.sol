// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GuardianLib.sol";

/// @title DeployerCouncil (GCSS)
/// @notice Protects deployer address using guardian voting
contract DeployerCouncil {
    using GuardianLib for GuardianLib.GuardianCouncil;

    address public deployer;
    GuardianLib.GuardianCouncil private council;

    constructor(address initDeployer, address[] calldata guardians) {
        deployer = initDeployer;
        council.init(guardians, 5, 3 days); // 5-of-7 threshold
    }

    function proposeRecovery(address newDeployer) external {
        council.proposeRecovery(newDeployer);
    }

    function approveRecovery() external {
        council.approveRecovery();
    }

    function executeRecovery() external {
        if (!council.canExecute()) revert GuardianLib.RecoveryNotMet();
        address old = deployer;
        deployer = council.active.proposed;
        council.markExecuted();
        emit GuardianLib.RecoveryExecuted(old, deployer);
    }

    function guardians() external view returns (address[] memory) {
        return council.guardians();
    }
}
