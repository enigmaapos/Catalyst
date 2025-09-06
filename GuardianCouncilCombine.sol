// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GuardianLib.sol";

/// @title Shared Guardian Council
/// @notice Combines GCSS + AGC into one contract
contract GuardianCouncil {
    using GuardianLib for GuardianLib.GuardianCouncil;

    address public deployer;
    address public admin;

    GuardianLib.GuardianCouncil private deployerCouncil;
    GuardianLib.GuardianCouncil private adminCouncil;

    constructor(
        address initDeployer,
        address initAdmin,
        address[] calldata deployerGuardians,
        address[] calldata adminGuardians
    ) {
        deployer = initDeployer;
        admin = initAdmin;
        deployerCouncil.init(deployerGuardians, 5, 3 days); // 5-of-7
        adminCouncil.init(adminGuardians, 5, 3 days);       // 5-of-7
    }

    // ---- Deployer Council ----
    function proposeDeployerRecovery(address newDeployer) external {
        deployerCouncil.proposeRecovery(newDeployer);
    }

    function approveDeployerRecovery() external {
        deployerCouncil.approveRecovery();
    }

    function executeDeployerRecovery() external {
        if (!deployerCouncil.canExecute()) revert GuardianLib.RecoveryNotMet();
        address old = deployer;
        deployer = deployerCouncil.active.proposed;
        deployerCouncil.markExecuted();
        emit GuardianLib.RecoveryExecuted(old, deployer);
    }

    function deployerGuardians() external view returns (address[] memory) {
        return deployerCouncil.guardians();
    }

    // ---- Admin Council ----
    function proposeAdminRecovery(address newAdmin) external {
        adminCouncil.proposeRecovery(newAdmin);
    }

    function approveAdminRecovery() external {
        adminCouncil.approveRecovery();
    }

    function executeAdminRecovery() external {
        if (!adminCouncil.canExecute()) revert GuardianLib.RecoveryNotMet();
        address old = admin;
        admin = adminCouncil.active.proposed;
        adminCouncil.markExecuted();
        emit GuardianLib.RecoveryExecuted(old, admin);
    }

    function adminGuardians() external view returns (address[] memory) {
        return adminCouncil.guardians();
    }
}
