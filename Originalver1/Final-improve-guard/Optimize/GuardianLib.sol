// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library GuardianLib {
    // A single, reusable struct for a guardian council
    struct GuardianCouncil {
        address[] guardians;
        mapping(address => bool) isGuardian;
        uint256 threshold;
    }

    // A single, reusable struct for a recovery request
    struct RecoveryRequest {
        address proposed;
        uint8 approvals;
        uint256 deadline;
        bool executed;
    }

    struct Storage {
        GuardianCouncil deployerCouncil;
        GuardianCouncil adminCouncil;
        RecoveryRequest deployerRecovery;
        mapping(address => bool) deployerHasApproved;
        RecoveryRequest adminRecovery;
        mapping(address => bool) adminHasApproved;
    }

    // Errors
    error ZeroAddress();
    error BadParam();
    error DuplicateGuardian();
    error Unauthorized();
    error NoRequest();
    error Expired();
    error AlreadyApproved();
    error ThresholdNotMet();
    error ExistingGuardian();
    error NotAGuardian();

    event GuardianSet(bytes32 indexed councilId, uint8 indexed idx, address guardian);
    event RecoveryProposed(bytes32 indexed councilId, address indexed proposer, address proposed, uint256 deadline);
    event RecoveryApproved(bytes32 indexed councilId, address indexed guardian, uint8 approvals);
    event Recovered(bytes32 indexed councilId, address oldAddress, address newAddress);

    bytes32 public constant DEPLOYER_COUNCIL_ID = keccak256("DEPLOYER");
    bytes32 public constant ADMIN_COUNCIL_ID = keccak256("ADMIN");

    function init(
        Storage storage s,
        address[] memory deployerGuardians,
        uint256 deployerThreshold,
        address[] memory adminGuardians,
        uint256 adminThreshold
    ) internal {
        _setGuardians(s.deployerCouncil, deployerGuardians, deployerThreshold);
        _setGuardians(s.adminCouncil, adminGuardians, adminThreshold);
    }

    function _setGuardians(
        GuardianCouncil storage council,
        address[] memory _guardians,
        uint256 _threshold
    ) private {
        require(_threshold > 0 && _threshold <= _guardians.length, "Invalid threshold");
        uint256 len = _guardians.length;
        for (uint256 i = 0; i < len; i++) {
            address g = _guardians[i];
            if (g == address(0)) revert ZeroAddress();
            if (council.isGuardian[g]) revert DuplicateGuardian();
            council.guardians.push(g);
            council.isGuardian[g] = true;
        }
        council.threshold = _threshold;
    }

    function proposeRecovery(
        Storage storage s,
        bytes32 councilId,
        address newAddress,
        uint256 recoveryWindow,
        address proposer
    ) internal {
        if (newAddress == address(0)) revert ZeroAddress();
        uint256 deadline = block.timestamp + recoveryWindow;
        if (councilId == DEPLOYER_COUNCIL_ID) {
            if (!s.deployerCouncil.isGuardian[proposer]) revert Unauthorized();
            s.deployerRecovery = RecoveryRequest({
                proposed: newAddress,
                approvals: 0,
                deadline: deadline,
                executed: false
            });
            for (uint256 i = 0; i < s.deployerCouncil.guardians.length; ++i) {
                s.deployerHasApproved[s.deployerCouncil.guardians[i]] = false;
            }
            emit RecoveryProposed(DEPLOYER_COUNCIL_ID, proposer, newAddress, s.deployerRecovery.deadline);
        } else if (councilId == ADMIN_COUNCIL_ID) {
            if (!s.adminCouncil.isGuardian[proposer]) revert Unauthorized();
            s.adminRecovery = RecoveryRequest({
                proposed: newAddress,
                approvals: 0,
                deadline: deadline,
                executed: false
            });
            for (uint256 i = 0; i < s.adminCouncil.guardians.length; ++i) {
                s.adminHasApproved[s.adminCouncil.guardians[i]] = false;
            }
            emit RecoveryProposed(ADMIN_COUNCIL_ID, proposer, newAddress, s.adminRecovery.deadline);
        } else {
            revert BadParam();
        }
    }

    function approveRecovery(
        Storage storage s,
        bytes32 councilId,
        address approver
    ) internal returns (uint8) {
        if (councilId == DEPLOYER_COUNCIL_ID) {
            if (!s.deployerCouncil.isGuardian[approver]) revert Unauthorized();
            RecoveryRequest storage recovery = s.deployerRecovery;
            if (recovery.proposed == address(0)) revert NoRequest();
            if (block.timestamp > recovery.deadline) revert Expired();
            if (recovery.executed) revert AlreadyApproved();
            if (s.deployerHasApproved[approver]) revert AlreadyApproved();

            s.deployerHasApproved[approver] = true;
            recovery.approvals++;
            emit RecoveryApproved(DEPLOYER_COUNCIL_ID, approver, recovery.approvals);
            return recovery.approvals;
        } else if (councilId == ADMIN_COUNCIL_ID) {
            if (!s.adminCouncil.isGuardian[approver]) revert Unauthorized();
            RecoveryRequest storage recovery = s.adminRecovery;
            if (recovery.proposed == address(0)) revert NoRequest();
            if (block.timestamp > recovery.deadline) revert Expired();
            if (recovery.executed) revert AlreadyApproved();
            if (s.adminHasApproved[approver]) revert AlreadyApproved();

            s.adminHasApproved[approver] = true;
            recovery.approvals++;
            emit RecoveryApproved(ADMIN_COUNCIL_ID, approver, recovery.approvals);
            return recovery.approvals;
        } else {
            revert BadParam();
        }
    }

    function executeRecovery(
        Storage storage s,
        bytes32 councilId
    ) internal returns (address) {
        if (councilId == DEPLOYER_COUNCIL_ID) {
            RecoveryRequest storage recovery = s.deployerRecovery;
            if (recovery.proposed == address(0)) revert NoRequest();
            if (block.timestamp > recovery.deadline) revert Expired();
            if (recovery.executed) revert AlreadyApproved();
            if (recovery.approvals < s.deployerCouncil.threshold) revert ThresholdNotMet();

            address old = s.deployerCouncil.guardians[0];
            address newAddress = recovery.proposed;
            recovery.executed = true;

            emit Recovered(DEPLOYER_COUNCIL_ID, old, newAddress);
            return newAddress;
        } else if (councilId == ADMIN_COUNCIL_ID) {
            RecoveryRequest storage recovery = s.adminRecovery;
            if (recovery.proposed == address(0)) revert NoRequest();
            if (block.timestamp > recovery.deadline) revert Expired();
            if (recovery.executed) revert AlreadyApproved();
            if (recovery.approvals < s.adminCouncil.threshold) revert ThresholdNotMet();
            address newAddress = recovery.proposed;
            recovery.executed = true;
            emit Recovered(ADMIN_COUNCIL_ID, address(0), newAddress);
            return newAddress;
        } else {
            revert BadParam();
        }
    }

    function isGuardian(Storage storage s, bytes32 councilId, address guardian) internal view returns (bool) {
        if (councilId == DEPLOYER_COUNCIL_ID) {
            return s.deployerCouncil.isGuardian[guardian];
        } else if (councilId == ADMIN_COUNCIL_ID) {
            return s.adminCouncil.isGuardian[guardian];
        } else {
            revert BadParam();
        }
    }

    function setGuardian(
        Storage storage s,
        bytes32 councilId,
        uint8 idx,
        address guardian
    ) internal {
        if (councilId == DEPLOYER_COUNCIL_ID) {
            GuardianCouncil storage council = s.deployerCouncil;
            if (idx >= council.guardians.length) revert BadParam();
            if (guardian == address(0)) revert ZeroAddress();
            if (council.isGuardian[guardian]) revert DuplicateGuardian();

            address old = council.guardians[idx];
            if (old != address(0)) council.isGuardian[old] = false;
            council.guardians[idx] = guardian;
            council.isGuardian[guardian] = true;
            emit GuardianSet(DEPLOYER_COUNCIL_ID, idx, guardian);
        } else if (councilId == ADMIN_COUNCIL_ID) {
            GuardianCouncil storage council = s.adminCouncil;
            if (idx >= council.guardians.length) revert BadParam();
            if (guardian == address(0)) revert ZeroAddress();
            if (council.isGuardian[guardian]) revert DuplicateGuardian();

            address old = council.guardians[idx];
            if (old != address(0)) council.isGuardian[old] = false;
            council.guardians[idx] = guardian;
            council.isGuardian[guardian] = true;
            emit GuardianSet(ADMIN_COUNCIL_ID, idx, guardian);
        } else {
            revert BadParam();
        }
    }
}
