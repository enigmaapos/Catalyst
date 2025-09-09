// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GuardianLib
 * @notice Council + recovery logic extracted to a library to keep main contract lean.
 * Now deployed as a separate contract and called externally.
 */
library GuardianLib {
    /* ========= Constants ========= */
    uint8 public constant DEPLOYER_GCOUNT    = 7;
    uint8 public constant DEPLOYER_THRESHOLD = 5;
    uint8 public constant ADMIN_GCOUNT       = 7;
    uint8 public constant ADMIN_THRESHOLD    = 5;
    uint256 public constant RECOVERY_WINDOW   = 3 days;

    bytes32 public constant COUNCIL_DEPLOYER = keccak256("DEPLOYER");
    bytes32 public constant COUNCIL_ADMIN    = keccak256("ADMIN");

    /* ========= Errors ========= */
    error ZeroAddress();
    error BadParam();
    error AlreadyExists();
    error Unauthorized();
    error NoRequest();
    error Expired();
    error AlreadyApproved();
    error Threshold();

    /* ========= Events ========= */
    event GuardianSet(bytes32 council, uint8 idx, address guardian);

    event DeployerRecoveryProposed(address indexed proposer, address proposed, uint256 deadline);
    event DeployerRecoveryApproved(address indexed guardian, uint8 approvals);
    event DeployerRecoveryExecuted(address indexed newDeployer);

    event AdminRecoveryProposed(address indexed proposer, address proposed, uint256 deadline);
    event AdminRecoveryApproved(address indexed guardian, uint8 approvals);
    event AdminRecoveryExecuted(address indexed newAdmin);

    /* ========= Storage ========= */
    struct RecoveryRequest {
        address proposed;
        uint64 deadline;
        uint8 approvals;
        bool executed;
    }

    struct Storage {
        address[] deployerGuardians;
        address[] adminGuardians;
        mapping(address => bool) isDeployerGuardian;
        mapping(address => bool) isAdminGuardian;
        mapping(address => bool) deployerHasApproved;
        mapping(address => bool) adminHasApproved;
        address deployerRecoveryProposer;
        address adminRecoveryProposer;
        RecoveryRequest deployerRecovery;
        RecoveryRequest adminRecovery;
        address deployerGuardianCouncil;
    }

    /* ========= Functions (all external) ========= */
    function init(Storage storage gu, address deployer) external {
        if (gu.deployerGuardianCouncil != address(0)) revert AlreadyExists();

        // Initialize arrays to correct length by pushing placeholder addresses
        for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
            gu.deployerGuardians.push();
        }
        for (uint8 i = 0; i < ADMIN_GCOUNT; ++i) {
            gu.adminGuardians.push();
        }

        gu.deployerGuardianCouncil = deployer;
    }

    function setDeployerGuardian(Storage storage gu, uint8 idx, address guardian) external {
        if (idx >= DEPLOYER_GCOUNT) revert BadParam();

        // Update mappings before overwriting the old guardian
        gu.isDeployerGuardian[gu.deployerGuardians[idx]] = false;
        gu.deployerGuardians[idx] = guardian;
        gu.isDeployerGuardian[guardian] = true;

        emit GuardianSet(COUNCIL_DEPLOYER, idx, guardian);
    }

    function setAdminGuardian(Storage storage gu, uint8 idx, address guardian) external {
        if (idx >= ADMIN_GCOUNT) revert BadParam();

        // Update mappings before overwriting the old guardian
        gu.isAdminGuardian[gu.adminGuardians[idx]] = false;
        gu.adminGuardians[idx] = guardian;
        gu.isAdminGuardian[guardian] = true;

        emit GuardianSet(COUNCIL_ADMIN, idx, guardian);
    }

    function proposeDeployerRecovery(Storage storage gu, address proposedDeployer) external {
        if (!gu.isDeployerGuardian[msg.sender]) revert Unauthorized();
        if (gu.deployerRecovery.proposed != address(0)) {
            if (block.timestamp < gu.deployerRecovery.deadline) revert AlreadyExists();
        }

        gu.deployerRecoveryProposer = msg.sender;
        gu.deployerRecovery = RecoveryRequest({
            proposed: proposedDeployer,
            approvals: 1,
            deadline: uint64(block.timestamp + RECOVERY_WINDOW),
            executed: false
        });

        unchecked {
            for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
                address gaddr = gu.deployerGuardians[i];
                if (gaddr != address(0)) gu.deployerHasApproved[gaddr] = false;
            }
        }

        gu.deployerHasApproved[msg.sender] = true;
        emit DeployerRecoveryProposed(msg.sender, proposedDeployer, gu.deployerRecovery.deadline);
    }

    function approveDeployerRecovery(Storage storage gu, address approver) external {
        if (!gu.isDeployerGuardian[approver]) revert Unauthorized();
        RecoveryRequest storage r = gu.deployerRecovery;
        if (r.proposed == address(0)) revert NoRequest();
        if (block.timestamp > r.deadline) revert Expired();
        if (r.executed) revert AlreadyApproved();
        if (gu.deployerHasApproved[approver]) revert AlreadyApproved();

        gu.deployerHasApproved[approver] = true;
        unchecked { r.approvals += 1; }
        emit DeployerRecoveryApproved(approver, r.approvals);
    }

    function executeDeployerRecovery(Storage storage gu) external returns (address newDeployer) {
        RecoveryRequest storage r = gu.deployerRecovery;
        if (r.proposed == address(0)) revert NoRequest();
        if (block.timestamp > r.deadline) revert Expired();
        if (r.executed) revert AlreadyApproved();
        if (r.approvals < DEPLOYER_THRESHOLD) revert Threshold();

        r.executed = true;
        newDeployer = r.proposed;
        emit DeployerRecoveryExecuted(newDeployer);
    }

    function proposeAdminRecovery(Storage storage gu, address newAdmin) external {
        if (!gu.isAdminGuardian[msg.sender]) revert Unauthorized();
        if (gu.adminRecovery.proposed != address(0)) {
            if (block.timestamp < gu.adminRecovery.deadline) revert AlreadyExists();
        }

        gu.adminRecoveryProposer = msg.sender;
        gu.adminRecovery = RecoveryRequest({
            proposed: newAdmin,
            approvals: 1,
            deadline: uint64(block.timestamp + RECOVERY_WINDOW),
            executed: false
        });

        unchecked {
            for (uint8 i = 0; i < ADMIN_GCOUNT; ++i) {
                address gaddr = gu.adminGuardians[i];
                if (gaddr != address(0)) gu.adminHasApproved[gaddr] = false;
            }
        }
        gu.adminHasApproved[msg.sender] = true;
        emit AdminRecoveryProposed(msg.sender, newAdmin, gu.adminRecovery.deadline);
    }

    function approveAdminRecovery(Storage storage gu, address approver) external {
        if (!gu.isAdminGuardian[approver]) revert Unauthorized();
        RecoveryRequest storage r = gu.adminRecovery;
        if (r.proposed == address(0)) revert NoRequest();
        if (block.timestamp > r.deadline) revert Expired();
        if (r.executed) revert AlreadyApproved();
        if (gu.adminHasApproved[approver]) revert AlreadyApproved();

        gu.adminHasApproved[approver] = true;
        unchecked { r.approvals += 1; }
        emit AdminRecoveryApproved(approver, r.approvals);
    }

    function executeAdminRecovery(Storage storage gu) external returns (address newAdmin) {
        RecoveryRequest storage r = gu.adminRecovery;
        if (r.proposed == address(0)) revert NoRequest();
        if (block.timestamp > r.deadline) revert Expired();
        if (r.executed) revert AlreadyApproved();
        if (r.approvals < ADMIN_THRESHOLD) revert Threshold();

        r.executed = true;
        newAdmin = r.proposed;
        emit AdminRecoveryExecuted(newAdmin);
    }

    // The `getStorage` function was removed. Here are replacement functions:

    function getDeployerGuardians(Storage storage gu) external view returns (address[] memory) {
        return gu.deployerGuardians;
    }

    function getAdminGuardians(Storage storage gu) external view returns (address[] memory) {
        return gu.adminGuardians;
    }

    function getDeployerRecovery(Storage storage gu) external view returns (RecoveryRequest memory) {
        return gu.deployerRecovery;
    }

    function getAdminRecovery(Storage storage gu) external view returns (RecoveryRequest memory) {
        return gu.adminRecovery;
    }
}
