// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GuardianLib
 * @notice Council + recovery logic extracted to a library to keep main contract lean.
 *         All functions are `internal` and invoked as member-functions via:
 *         `using GuardianLib for GuardianLib.Storage;`
 */
library GuardianLib {
    /* ========= Constants ========= */
    uint8  internal constant DEPLOYER_GCOUNT    = 7;
    uint8  internal constant DEPLOYER_THRESHOLD = 5;
    uint8  internal constant ADMIN_GCOUNT       = 7;
    uint8  internal constant ADMIN_THRESHOLD    = 5;
    uint256 internal constant RECOVERY_WINDOW   = 3 days;

    bytes32 internal constant COUNCIL_DEPLOYER = keccak256("DEPLOYER");
    bytes32 internal constant COUNCIL_ADMIN    = keccak256("ADMIN");

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
        uint8   approvals;
        uint64  deadline;
        bool    executed;
    }

    struct Storage {
        // councils
        address[DEPLOYER_GCOUNT] deployerGuardians;
        mapping(address => bool) isDeployerGuardian;

        address[ADMIN_GCOUNT] adminGuardians;
        mapping(address => bool) isAdminGuardian;

        // recovery state
        RecoveryRequest deployerRecovery;
        mapping(address => bool) deployerHasApproved;

        RecoveryRequest adminRecovery;
        mapping(address => bool) adminHasApproved;
    }

    /* ========= Init ========= */
    function initGuardians(
        Storage storage gu,
        address[] memory deployers,
        address[] memory admins
    ) internal {
        if (deployers.length != DEPLOYER_GCOUNT) revert BadParam();
        if (admins.length    != ADMIN_GCOUNT)    revert BadParam();

        // Set deployer council with uniqueness checks
        unchecked {
            for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
                address a = deployers[i];
                if (a == address(0)) revert ZeroAddress();
                if (gu.isDeployerGuardian[a]) revert AlreadyExists();
                gu.deployerGuardians[i] = a;
                gu.isDeployerGuardian[a] = true;
                emit GuardianSet(COUNCIL_DEPLOYER, i, a);

                // pairwise uniqueness O(n^2) for tiny n
                for (uint8 j = i + 1; j < DEPLOYER_GCOUNT; ++j) {
                    if (deployers[j] == a) revert AlreadyExists();
                }
            }
            for (uint8 i2 = 0; i2 < ADMIN_GCOUNT; ++i2) {
                address a2 = admins[i2];
                if (a2 == address(0)) revert ZeroAddress();
                if (gu.isAdminGuardian[a2]) revert AlreadyExists();
                gu.adminGuardians[i2] = a2;
                gu.isAdminGuardian[a2] = true;
                emit GuardianSet(COUNCIL_ADMIN, i2, a2);

                for (uint8 j2 = i2 + 1; j2 < ADMIN_GCOUNT; ++j2) {
                    if (admins[j2] == a2) revert AlreadyExists();
                }
            }
        }
    }

    /* ========= Membership checks (optional wrappers) ========= */
    function guardianOnlyDeployer(Storage storage gu, address who) internal view {
        if (!gu.isDeployerGuardian[who]) revert Unauthorized();
    }

    function guardianOnlyAdmin(Storage storage gu, address who) internal view {
        if (!gu.isAdminGuardian[who]) revert Unauthorized();
    }

    /* ========= Council rotation ========= */
    function setDeployerGuardian(Storage storage gu, uint8 idx, address guardian) internal {
        if (idx >= DEPLOYER_GCOUNT) revert BadParam();
        if (guardian == address(0)) revert ZeroAddress();

        address old = gu.deployerGuardians[idx];
        if (old != address(0)) {
            gu.isDeployerGuardian[old] = false;
        }
        if (gu.isDeployerGuardian[guardian]) revert AlreadyExists();

        gu.deployerGuardians[idx] = guardian;
        gu.isDeployerGuardian[guardian] = true;
        emit GuardianSet(COUNCIL_DEPLOYER, idx, guardian);
    }

    function setAdminGuardian(Storage storage gu, uint8 idx, address guardian) internal {
        if (idx >= ADMIN_GCOUNT) revert BadParam();
        if (guardian == address(0)) revert ZeroAddress();

        address old = gu.adminGuardians[idx];
        if (old != address(0)) {
            gu.isAdminGuardian[old] = false;
        }
        if (gu.isAdminGuardian[guardian]) revert AlreadyExists();

        gu.adminGuardians[idx] = guardian;
        gu.isAdminGuardian[guardian] = true;
        emit GuardianSet(COUNCIL_ADMIN, idx, guardian);
    }

    /* ========= Deployer recovery (7:5) ========= */
    function proposeDeployerRecovery(Storage storage gu, address newDeployer) internal {
        if (newDeployer == address(0)) revert ZeroAddress();

        gu.deployerRecovery = RecoveryRequest({
            proposed: newDeployer,
            approvals: 0,
            deadline: uint64(block.timestamp + RECOVERY_WINDOW),
            executed: false
        });

        // reset approvals
        unchecked {
            for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
                address gaddr = gu.deployerGuardians[i];
                if (gaddr != address(0)) gu.deployerHasApproved[gaddr] = false;
            }
        }

        emit DeployerRecoveryProposed(msg.sender, newDeployer, gu.deployerRecovery.deadline);
    }

    function approveDeployerRecovery(Storage storage gu, address approver) internal {
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

    function executeDeployerRecovery(Storage storage gu) internal returns (address newDeployer) {
        RecoveryRequest storage r = gu.deployerRecovery;
        if (r.proposed == address(0)) revert NoRequest();
        if (block.timestamp > r.deadline) revert Expired();
        if (r.executed) revert AlreadyApproved();
        if (r.approvals < DEPLOYER_THRESHOLD) revert Threshold();

        r.executed = true;
        newDeployer = r.proposed;
        emit DeployerRecoveryExecuted(newDeployer);
    }

    /* ========= Admin recovery (7:5) ========= */
    function proposeAdminRecovery(Storage storage gu, address newAdmin) internal {
        if (newAdmin == address(0)) revert ZeroAddress();

        gu.adminRecovery = RecoveryRequest({
            proposed: newAdmin,
            approvals: 0,
            deadline: uint64(block.timestamp + RECOVERY_WINDOW),
            executed: false
        });

        unchecked {
            for (uint8 i = 0; i < ADMIN_GCOUNT; ++i) {
                address gaddr = gu.adminGuardians[i];
                if (gaddr != address(0)) gu.adminHasApproved[gaddr] = false;
            }
        }

        emit AdminRecoveryProposed(msg.sender, newAdmin, gu.adminRecovery.deadline);
    }

    function approveAdminRecovery(Storage storage gu, address approver) internal {
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

    function executeAdminRecovery(Storage storage gu) internal returns (address newAdmin) {
        RecoveryRequest storage r = gu.adminRecovery;
        if (r.proposed == address(0)) revert NoRequest();
        if (block.timestamp > r.deadline) revert Expired();
        if (r.executed) revert AlreadyApproved();
        if (r.approvals < ADMIN_THRESHOLD) revert Threshold();

        r.executed = true;
        newAdmin = r.proposed;
        emit AdminRecoveryExecuted(newAdmin);
    }
}
