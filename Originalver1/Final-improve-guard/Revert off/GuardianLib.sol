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
    error InvalidThreshold();

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
        if (_threshold == 0 || _threshold > _guardians.length) revert InvalidThreshold();
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
        if (councilId == DEPLOYER_COUNCIL_ID) {
            if (!s.deployerCouncil.isGuardian[proposer]) revert Unauthorized();
            s.deployerRecovery = RecoveryRequest({
                proposed: newAddress,
                approvals: 0,
                deadline: block.timestamp + recoveryWindow,
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
                deadline: block.timestamp + recoveryWindow,
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
        address guardian
    ) internal returns (uint8) {
        if (councilId == DEPLOYER_COUNCIL_ID) {
            if (!s.deployerCouncil.isGuardian[guardian]) revert Unauthorized();
            RecoveryRequest storage r = s.deployerRecovery;
            if (r.proposed == address(0)) revert NoRequest();
            if (block.timestamp > r.deadline) revert Expired();
            if (s.deployerHasApproved[guardian]) revert AlreadyApproved();
            s.deployerHasApproved[guardian] = true;
            r.approvals++;
            emit RecoveryApproved(DEPLOYER_COUNCIL_ID, guardian, r.approvals);
            return r.approvals;
        } else if (councilId == ADMIN_COUNCIL_ID) {
            if (!s.adminCouncil.isGuardian[guardian]) revert Unauthorized();
            RecoveryRequest storage r = s.adminRecovery;
            if (r.proposed == address(0)) revert NoRequest();
            if (block.timestamp > r.deadline) revert Expired();
            if (s.adminHasApproved[guardian]) revert AlreadyApproved();
            s.adminHasApproved[guardian] = true;
            r.approvals++;
            emit RecoveryApproved(ADMIN_COUNCIL_ID, guardian, r.approvals);
            return r.approvals;
        } else {
            revert BadParam();
        }
    }

    function executeRecovery(Storage storage s, bytes32 councilId) internal returns (address) {
        if (councilId == DEPLOYER_COUNCIL_ID) {
            RecoveryRequest storage r = s.deployerRecovery;
            if (r.proposed == address(0)) revert NoRequest();
            if (r.approvals < s.deployerCouncil.threshold) revert ThresholdNotMet();
            if (r.executed) revert ExistingGuardian();
            r.executed = true;
            address recoveredAddress = r.proposed;
            for (uint256 i = 0; i < s.deployerCouncil.guardians.length; ++i) {
                s.deployerCouncil.isGuardian[s.deployerCouncil.guardians[i]] = false;
            }
            delete s.deployerCouncil.guardians;
            s.deployerCouncil.guardians.push(recoveredAddress);
            s.deployerCouncil.isGuardian[recoveredAddress] = true;
            emit Recovered(DEPLOYER_COUNCIL_ID, address(0), recoveredAddress);
            return recoveredAddress;
        } else if (councilId == ADMIN_COUNCIL_ID) {
            RecoveryRequest storage r = s.adminRecovery;
            if (r.proposed == address(0)) revert NoRequest();
            if (r.approvals < s.adminCouncil.threshold) revert ThresholdNotMet();
            if (r.executed) revert ExistingGuardian();
            r.executed = true;
            address recoveredAddress = r.proposed;
            for (uint256 i = 0; i < s.adminCouncil.guardians.length; ++i) {
                s.adminCouncil.isGuardian[s.adminCouncil.guardians[i]] = false;
            }
            delete s.adminCouncil.guardians;
            s.adminCouncil.guardians.push(recoveredAddress);
            s.adminCouncil.isGuardian[recoveredAddress] = true;
            emit Recovered(ADMIN_COUNCIL_ID, address(0), recoveredAddress);
            return recoveredAddress;
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
            if (idx >= s.deployerCouncil.guardians.length) revert BadParam();
            if (guardian == address(0)) revert ZeroAddress();
            if (s.deployerCouncil.isGuardian[guardian]) revert DuplicateGuardian();

            address old = s.deployerCouncil.guardians[idx];
            if (old != address(0)) s.deployerCouncil.isGuardian[old] = false;
            s.deployerCouncil.guardians[idx] = guardian;
            s.deployerCouncil.isGuardian[guardian] = true;
            emit GuardianSet(DEPLOYER_COUNCIL_ID, idx, guardian);
        } else if (councilId == ADMIN_COUNCIL_ID) {
            if (idx >= s.adminCouncil.guardians.length) revert BadParam();
            if (guardian == address(0)) revert ZeroAddress();
            if (s.adminCouncil.isGuardian[guardian]) revert DuplicateGuardian();

            address old = s.adminCouncil.guardians[idx];
            if (old != address(0)) s.adminCouncil.isGuardian[old] = false;
            s.adminCouncil.guardians[idx] = guardian;
            s.adminCouncil.isGuardian[guardian] = true;
            emit GuardianSet(ADMIN_COUNCIL_ID, idx, guardian);
        } else {
            revert BadParam();
        }
    }
}
