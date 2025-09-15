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
        if (_threshold == 0 || _threshold > _guardians.length) revert BadParam();
        for (uint256 i = 0; i < _guardians.length; i++) {
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

        GuardianCouncil storage council;
        RecoveryRequest storage recovery;
        mapping(address => bool) storage hasApproved;

        (council, recovery, hasApproved) = _getCouncilAndRequest(s, councilId);

        if (!council.isGuardian[proposer]) revert Unauthorized();

        recovery.proposed = newAddress;
        recovery.approvals = 0;
        recovery.deadline = block.timestamp + recoveryWindow;
        recovery.executed = false;

        for (uint256 i = 0; i < council.guardians.length; ++i) {
            hasApproved[council.guardians[i]] = false;
        }

        emit RecoveryProposed(councilId, proposer, newAddress, recovery.deadline);
    }

    function approveRecovery(
        Storage storage s,
        bytes32 councilId,
        address approver
    ) internal returns (uint8) {
        GuardianCouncil storage council;
        RecoveryRequest storage recovery;
        mapping(address => bool) storage hasApproved;

        (council, recovery, hasApproved) = _getCouncilAndRequest(s, councilId);

        if (!council.isGuardian[approver]) revert Unauthorized();
        if (recovery.proposed == address(0)) revert NoRequest();
        if (block.timestamp > recovery.deadline) revert Expired();
        if (recovery.executed || hasApproved[approver]) revert AlreadyApproved();

        hasApproved[approver] = true;
        recovery.approvals++;

        emit RecoveryApproved(councilId, approver, recovery.approvals);
        return recovery.approvals;
    }

    function executeRecovery(
        Storage storage s,
        bytes32 councilId
    ) internal returns (address) {
        GuardianCouncil storage council;
        RecoveryRequest storage recovery;
        mapping(address => bool) storage hasApproved;

        (council, recovery, hasApproved) = _getCouncilAndRequest(s, councilId);

        if (recovery.proposed == address(0)) revert NoRequest();
        if (block.timestamp > recovery.deadline) revert Expired();
        if (recovery.executed) revert AlreadyApproved();
        if (recovery.approvals < council.threshold) revert ThresholdNotMet();
        
        address newAddress = recovery.proposed;
        recovery.executed = true;
        
        // This is a special case for the deployer council.
        // It's not clear what the intent is for the oldAddress in the admin council.
        // Assuming the first guardian is the old address for the deployer council
        // and address(0) for the admin council based on your original code.
        address oldAddress = (councilId == DEPLOYER_COUNCIL_ID) ? council.guardians[0] : address(0);
        
        emit Recovered(councilId, oldAddress, newAddress);
        return newAddress;
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
        GuardianCouncil storage council;
        if (councilId == DEPLOYER_COUNCIL_ID) {
            council = s.deployerCouncil;
        } else if (councilId == ADMIN_COUNCIL_ID) {
            council = s.adminCouncil;
        } else {
            revert BadParam();
        }

        if (idx >= council.guardians.length) revert BadParam();
        if (guardian == address(0)) revert ZeroAddress();
        if (council.isGuardian[guardian]) revert DuplicateGuardian();

        address old = council.guardians[idx];
        if (old != address(0)) council.isGuardian[old] = false;
        council.guardians[idx] = guardian;
        council.isGuardian[guardian] = true;
        emit GuardianSet(councilId, idx, guardian);
    }
    
    function _getCouncilAndRequest(Storage storage s, bytes32 councilId) private view returns (GuardianCouncil storage, RecoveryRequest storage, mapping(address => bool) storage) {
        if (councilId == DEPLOYER_COUNCIL_ID) {
            return (s.deployerCouncil, s.deployerRecovery, s.deployerHasApproved);
        } else if (councilId == ADMIN_COUNCIL_ID) {
            return (s.adminCouncil, s.adminRecovery, s.adminHasApproved);
        } else {
            revert BadParam();
        }
    }
}
