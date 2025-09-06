// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Guardian Council Security System (GCSS + AGC)
/// @notice Standalone guardian council logic (deployer + admin recovery flows).
/// @dev Designed to be modular and attachable to upgradeable contracts.
contract GuardianCouncil {
    // ------------------------
    // Custom errors
    // ------------------------
    error ZeroAddress();
    error NotGuardian();
    error AlreadyApproved();
    error RequestExpired();
    error ThresholdNotMet();
    error NoActiveRequest();
    error AlreadyExecuted();
    error BadParam();

    // ------------------------
    // Deployer Guardian Council (GCSS)
    // ------------------------
    address public deployerAddress;
    uint8 public constant DEPLOYER_GCOUNT = 7;
    uint8 public constant DEPLOYER_THRESHOLD = 5;
    address[DEPLOYER_GCOUNT] public deployerGuardians;
    mapping(address => bool) public isDeployerGuardian;

    // ------------------------
    // Admin Guardian Council (AGC)
    // ------------------------
    address public primaryAdmin;
    uint8 public constant ADMIN_GCOUNT = 7;
    uint8 public constant ADMIN_THRESHOLD = 5;
    address[ADMIN_GCOUNT] public adminGuardians;
    mapping(address => bool) public isAdminGuardian;

    // ------------------------
    // Recovery request struct
    // ------------------------
    struct Recovery {
        address proposed;
        uint8 approvals;
        uint256 deadline;
        bool executed;
    }

    uint256 public constant RECOVERY_WINDOW = 3 days;

    Recovery public deployerRecovery;
    mapping(address => bool) public deployerHasApproved;

    Recovery public adminRecovery;
    mapping(address => bool) public adminHasApproved;

    // ------------------------
    // Events
    // ------------------------
    event GuardianSet(bytes32 indexed council, uint8 index, address guardian);
    event DeployerRecoveryProposed(address indexed guardian, address proposed, uint256 deadline);
    event DeployerRecoveryApproved(address indexed guardian, uint8 approvals);
    event DeployerRecovered(address indexed oldDeployer, address indexed newDeployer);
    event AdminRecoveryProposed(address indexed guardian, address proposed, uint256 deadline);
    event AdminRecoveryApproved(address indexed guardian, uint8 approvals);
    event AdminRecovered(address indexed newAdmin);

    // ------------------------
    // Modifiers
    // ------------------------
    modifier onlyDeployerGuardian() {
        if (!isDeployerGuardian[msg.sender]) revert NotGuardian();
        _;
    }

    modifier onlyAdminGuardian() {
        if (!isAdminGuardian[msg.sender]) revert NotGuardian();
        _;
    }

    // ------------------------
    // Guardian management (by admin)
    // ------------------------
    function setDeployerGuardian(uint8 idx, address guardian) external {
        if (idx >= DEPLOYER_GCOUNT) revert BadParam();
        address old = deployerGuardians[idx];
        if (old != address(0)) isDeployerGuardian[old] = false;
        deployerGuardians[idx] = guardian;
        if (guardian != address(0)) isDeployerGuardian[guardian] = true;
        emit GuardianSet(keccak256("DEPLOYER"), idx, guardian);
    }

    function setAdminGuardian(uint8 idx, address guardian) external {
        if (idx >= ADMIN_GCOUNT) revert BadParam();
        address old = adminGuardians[idx];
        if (old != address(0)) isAdminGuardian[old] = false;
        adminGuardians[idx] = guardian;
        if (guardian != address(0)) isAdminGuardian[guardian] = true;
        emit GuardianSet(keccak256("ADMIN"), idx, guardian);
    }

    // ------------------------
    // Deployer recovery flow
    // ------------------------
    function proposeDeployerRecovery(address newDeployer) external onlyDeployerGuardian {
        if (newDeployer == address(0)) revert ZeroAddress();
        deployerRecovery = Recovery({ proposed: newDeployer, approvals: 0, deadline: block.timestamp + RECOVERY_WINDOW, executed: false });
        for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
            address gaddr = deployerGuardians[i];
            if (gaddr != address(0)) deployerHasApproved[gaddr] = false;
        }
        emit DeployerRecoveryProposed(msg.sender, newDeployer, deployerRecovery.deadline);
    }

    function approveDeployerRecovery() external onlyDeployerGuardian {
        if (deployerRecovery.proposed == address(0)) revert NoActiveRequest();
        if (deployerRecovery.executed) revert AlreadyExecuted();
        if (block.timestamp > deployerRecovery.deadline) revert RequestExpired();
        if (deployerHasApproved[msg.sender]) revert AlreadyApproved();
        deployerHasApproved[msg.sender] = true;
        deployerRecovery.approvals++;
        emit DeployerRecoveryApproved(msg.sender, deployerRecovery.approvals);
    }

    function executeDeployerRecovery() external {
        if (deployerRecovery.proposed == address(0)) revert NoActiveRequest();
        if (deployerRecovery.executed) revert AlreadyExecuted();
        if (block.timestamp > deployerRecovery.deadline) revert RequestExpired();
        if (deployerRecovery.approvals < DEPLOYER_THRESHOLD) revert ThresholdNotMet();

        address old = deployerAddress;
        deployerAddress = deployerRecovery.proposed;
        deployerRecovery.executed = true;

        for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
            if (deployerGuardians[i] == old) {
                deployerGuardians[i] = address(0);
                isDeployerGuardian[old] = false;
                emit GuardianSet(keccak256("DEPLOYER"), i, address(0));
                break;
            }
        }

        emit DeployerRecovered(old, deployerAddress);
    }

    // ------------------------
    // Admin recovery flow (AGC)
    // ------------------------
    function proposeAdminRecovery(address newAdmin) external onlyAdminGuardian {
        if (newAdmin == address(0)) revert ZeroAddress();
        adminRecovery = Recovery({ proposed: newAdmin, approvals: 0, deadline: block.timestamp + RECOVERY_WINDOW, executed: false });
        for (uint8 i = 0; i < ADMIN_GCOUNT; ++i) {
            address gaddr = adminGuardians[i];
            if (gaddr != address(0)) adminHasApproved[gaddr] = false;
        }
        emit AdminRecoveryProposed(msg.sender, newAdmin, adminRecovery.deadline);
    }

    function approveAdminRecovery() external onlyAdminGuardian {
        if (adminRecovery.proposed == address(0)) revert NoActiveRequest();
        if (adminRecovery.executed) revert AlreadyExecuted();
        if (block.timestamp > adminRecovery.deadline) revert RequestExpired();
        if (adminHasApproved[msg.sender]) revert AlreadyApproved();
        adminHasApproved[msg.sender] = true;
        adminRecovery.approvals++;
        emit AdminRecoveryApproved(msg.sender, adminRecovery.approvals);
    }

    function executeAdminRecovery() external {
        if (adminRecovery.proposed == address(0)) revert NoActiveRequest();
        if (adminRecovery.executed) revert AlreadyExecuted();
        if (block.timestamp > adminRecovery.deadline) revert RequestExpired();
        if (adminRecovery.approvals < ADMIN_THRESHOLD) revert ThresholdNotMet();

        primaryAdmin = adminRecovery.proposed;
        adminRecovery.executed = true;

        emit AdminRecovered(primaryAdmin);
    }
}
