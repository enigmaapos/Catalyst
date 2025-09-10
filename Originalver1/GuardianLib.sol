// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

library GuardianLib {
    // Errors (gas-cheap)
    error ZeroAddress();
    error BadParam();
    error Unauthorized();
    error NoRequest();
    error Expired();
    error AlreadyApproved();
    error Threshold();

    // Constants
    uint8 public constant DEPLOYER_GCOUNT = 7;
    uint8 public constant DEPLOYER_THRESHOLD = 5;
    uint8 public constant ADMIN_GCOUNT = 7;
    uint8 public constant ADMIN_THRESHOLD = 5;
    uint256 public constant RECOVERY_WINDOW = 3 days;

    struct RecoveryRequest {
        address proposed;
        uint8 approvals;
        uint256 deadline;
        bool executed;
    }

    struct Storage {
        address[DEPLOYER_GCOUNT] deployerGuardians;
        mapping(address => bool) isDeployerGuardian;
        address[ADMIN_GCOUNT] adminGuardians;
        mapping(address => bool) isAdminGuardian;
        RecoveryRequest deployerRecovery;
        mapping(address => bool) deployerHasApproved;
        RecoveryRequest adminRecovery;
        mapping(address => bool) adminHasApproved;
    }

    event GuardianSet(bytes32 council, uint8 idx, address guardian);
    event DeployerRecoveryProposed(address indexed proposer, address proposed, uint256 deadline);
    event DeployerRecoveryApproved(address indexed guardian, uint8 approvals);
    event DeployerRecovered(address indexed oldDeployer, address indexed newDeployer);
    event AdminRecoveryProposed(address indexed proposer, address proposed, uint256 deadline);
    event AdminRecoveryApproved(address indexed guardian, uint8 approvals);
    event AdminRecovered(address indexed newAdmin);

    function init(Storage storage s, address[DEPLOYER_GCOUNT] calldata deployerGuardians, address[ADMIN_GCOUNT] calldata adminGuardians) internal {
        for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
            address a = deployerGuardians[i];
            s.deployerGuardians[i] = a;
            if (a != address(0)) s.isDeployerGuardian[a] = true;
            emit GuardianSet(keccak256("DEPLOYER"), i, a);
        }
        for (uint8 j = 0; j < ADMIN_GCOUNT; ++j) {
            address a = adminGuardians[j];
            s.adminGuardians[j] = a;
            if (a != address(0)) s.isAdminGuardian[a] = true;
            emit GuardianSet(keccak256("ADMIN"), j, a);
        }
    }

    function setDeployerGuardian(Storage storage s, uint8 idx, address guardian) internal {
        if (idx >= DEPLOYER_GCOUNT) revert BadParam();
        address old = s.deployerGuardians[idx];
        if (old != address(0)) s.isDeployerGuardian[old] = false;
        s.deployerGuardians[idx] = guardian;
        if (guardian != address(0)) s.isDeployerGuardian[guardian] = true;
        emit GuardianSet(keccak256("DEPLOYER"), idx, guardian);
    }

    function setAdminGuardian(Storage storage s, uint8 idx, address guardian) internal {
        if (idx >= ADMIN_GCOUNT) revert BadParam();
        address old = s.adminGuardians[idx];
        if (old != address(0)) s.isAdminGuardian[old] = false;
        s.adminGuardians[idx] = guardian;
        if (guardian != address(0)) s.isAdminGuardian[guardian] = true;
        emit GuardianSet(keccak256("ADMIN"), idx, guardian);
    }

    function proposeDeployerRecovery(Storage storage s, address newDeployer, address sender) internal {
        if (!s.isDeployerGuardian[sender]) revert Unauthorized();
        if (newDeployer == address(0)) revert ZeroAddress();
        s.deployerRecovery = RecoveryRequest({
            proposed: newDeployer,
            approvals: 0,
            deadline: block.timestamp + RECOVERY_WINDOW,
            executed: false
        });
        for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
            address gaddr = s.deployerGuardians[i];
            if (gaddr != address(0)) s.deployerHasApproved[gaddr] = false;
        }
        emit DeployerRecoveryProposed(sender, newDeployer, s.deployerRecovery.deadline);
    }

    function approveDeployerRecovery(Storage storage s, address sender) internal {
        if (!s.isDeployerGuardian[sender]) revert Unauthorized();
        if (s.deployerRecovery.proposed == address(0)) revert NoRequest();
        if (block.timestamp > s.deployerRecovery.deadline) revert Expired();
        if (s.deployerRecovery.executed) revert AlreadyApproved();
        if (s.deployerHasApproved[sender]) revert AlreadyApproved();
        s.deployerHasApproved[sender] = true;
        s.deployerRecovery.approvals += 1;
        emit DeployerRecoveryApproved(sender, s.deployerRecovery.approvals);
    }

    function executeDeployerRecovery(Storage storage s) internal returns(address) {
        if (s.deployerRecovery.proposed == address(0)) revert NoRequest();
        if (block.timestamp > s.deployerRecovery.deadline) revert Expired();
        if (s.deployerRecovery.executed) revert AlreadyApproved();
        if (s.deployerRecovery.approvals < DEPLOYER_THRESHOLD) revert Threshold();

        address old = s.deployerRecovery.proposed; // The original contract's deployerAddress will be replaced
        s.deployerRecovery.executed = true;

        if (s.isDeployerGuardian[old]) {
            for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
                if (s.deployerGuardians[i] == old) {
                    s.isDeployerGuardian[old] = false;
                    s.deployerGuardians[i] = address(0);
                    emit GuardianSet(keccak256("DEPLOYER"), i, address(0));
                    break;
                }
            }
        }
        return s.deployerRecovery.proposed;
    }

    function proposeAdminRecovery(Storage storage s, address newAdmin, address sender) internal {
        if (!s.isAdminGuardian[sender]) revert Unauthorized();
        if (newAdmin == address(0)) revert ZeroAddress();
        s.adminRecovery = RecoveryRequest({
            proposed: newAdmin,
            approvals: 0,
            deadline: block.timestamp + RECOVERY_WINDOW,
            executed: false
        });
        for (uint8 i = 0; i < ADMIN_GCOUNT; ++i) {
            address gaddr = s.adminGuardians[i];
            if (gaddr != address(0)) s.adminHasApproved[gaddr] = false;
        }
        emit AdminRecoveryProposed(sender, newAdmin, s.adminRecovery.deadline);
    }

    function approveAdminRecovery(Storage storage s, address sender) internal {
        if (!s.isAdminGuardian[sender]) revert Unauthorized();
        if (s.adminRecovery.proposed == address(0)) revert NoRequest();
        if (block.timestamp > s.adminRecovery.deadline) revert Expired();
        if (s.adminRecovery.executed) revert AlreadyApproved();
        if (s.adminHasApproved[sender]) revert AlreadyApproved();
        s.adminHasApproved[sender] = true;
        s.adminRecovery.approvals += 1;
        emit AdminRecoveryApproved(sender, s.adminRecovery.approvals);
    }

    function executeAdminRecovery(Storage storage s) internal returns(address) {
        if (s.adminRecovery.proposed == address(0)) revert NoRequest();
        if (block.timestamp > s.adminRecovery.deadline) revert Expired();
        if (s.adminRecovery.executed) revert AlreadyApproved();
        if (s.adminRecovery.approvals < ADMIN_THRESHOLD) revert Threshold();

        s.adminRecovery.executed = true;
        return s.adminRecovery.proposed;
    }
}
