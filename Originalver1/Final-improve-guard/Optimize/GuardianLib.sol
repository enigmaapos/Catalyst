// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library GuardianLib {
    // --- Structs (KEEP ORDER & TYPES for storage safety!) ---
    struct GuardianCouncil {
        address[] guardians;
        mapping(address => bool) isGuardian;
        uint256 threshold;
    }

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

    // --- Errors (short) ---
    error GZ_ZeroAddress();
    error GZ_BadParam();
    error GZ_DuplicateGuardian();
    error GZ_Unauthorized();
    error GZ_NoRequest();
    error GZ_Expired();
    error GZ_AlreadyApproved();
    error GZ_ThresholdNotMet();
    error GZ_NotAGuardian();
    error GZ_IndexOutOfRange();

    // --- Events (unchanged) ---
    event GuardianSet(bytes32 indexed councilId, uint8 indexed idx, address guardian);
    event RecoveryProposed(bytes32 indexed councilId, address indexed proposer, address proposed, uint256 deadline);
    event RecoveryApproved(bytes32 indexed councilId, address indexed guardian, uint8 approvals);
    event Recovered(bytes32 indexed councilId, address oldAddress, address newAddress);

    // --- Council IDs (kept as bytes32) ---
    bytes32 public constant DEPLOYER_COUNCIL_ID = keccak256("DEPLOYER");
    bytes32 public constant ADMIN_COUNCIL_ID = keccak256("ADMIN");

    // --- Helpers to get council pointer (storage safe) ---
    function _getCouncil(Storage storage s, bytes32 councilId) private view returns (GuardianCouncil storage) {
        if (councilId == DEPLOYER_COUNCIL_ID) return s.deployerCouncil;
        if (councilId == ADMIN_COUNCIL_ID) return s.adminCouncil;
        revert GZ_BadParam();
    }

    // helper to pick the correct recovery & approvals mapping (we return by reference via locals)
    function _getRecoveryAndApprovals(
        Storage storage s,
        bytes32 councilId
    )
        private
        view
        returns (RecoveryRequest storage req, mapping(address => bool) storage approvals)
    {
        if (councilId == DEPLOYER_COUNCIL_ID) {
            return (s.deployerRecovery, s.deployerHasApproved);
        } else if (councilId == ADMIN_COUNCIL_ID) {
            return (s.adminRecovery, s.adminHasApproved);
        } else {
            revert GZ_BadParam();
        }
    }

    // ---------------------------
    // Initialization
    // ---------------------------
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
        if (_threshold == 0 || _threshold > _guardians.length) revert GZ_BadParam();
        uint256 len = _guardians.length;
        for (uint256 i = 0; i < len; ) {
            address g = _guardians[i];
            if (g == address(0)) revert GZ_ZeroAddress();
            if (council.isGuardian[g]) revert GZ_DuplicateGuardian();
            council.guardians.push(g);
            council.isGuardian[g] = true;
            unchecked { ++i; }
        }
        council.threshold = _threshold;
    }

    // ---------------------------
    // Propose recovery
    // ---------------------------
    function proposeRecovery(
        Storage storage s,
        bytes32 councilId,
        address newAddress,
        uint256 recoveryWindow,
        address proposer
    ) internal {
        if (newAddress == address(0)) revert GZ_ZeroAddress();

        GuardianCouncil storage council = _getCouncil(s, councilId);
        if (!council.isGuardian[proposer]) revert GZ_Unauthorized();

        // choose correct recovery struct & approvals map
        if (councilId == DEPLOYER_COUNCIL_ID) {
            s.deployerRecovery.proposed = newAddress;
            s.deployerRecovery.approvals = 0;
            s.deployerRecovery.deadline = block.timestamp + recoveryWindow;
            s.deployerRecovery.executed = false;

            // reset approvals map for the deployer council
            uint256 len = council.guardians.length;
            for (uint256 i = 0; i < len; ) {
                s.deployerHasApproved[council.guardians[i]] = false;
                unchecked { ++i; }
            }
            emit RecoveryProposed(DEPLOYER_COUNCIL_ID, proposer, newAddress, s.deployerRecovery.deadline);
            return;
        }

        if (councilId == ADMIN_COUNCIL_ID) {
            s.adminRecovery.proposed = newAddress;
            s.adminRecovery.approvals = 0;
            s.adminRecovery.deadline = block.timestamp + recoveryWindow;
            s.adminRecovery.executed = false;

            uint256 len2 = council.guardians.length;
            for (uint256 i = 0; i < len2; ) {
                s.adminHasApproved[council.guardians[i]] = false;
                unchecked { ++i; }
            }
            emit RecoveryProposed(ADMIN_COUNCIL_ID, proposer, newAddress, s.adminRecovery.deadline);
            return;
        }

        revert GZ_BadParam();
    }

    // ---------------------------
    // Approve recovery
    // ---------------------------
    function approveRecovery(
        Storage storage s,
        bytes32 councilId,
        address approver
    ) internal returns (uint8) {
        GuardianCouncil storage council = _getCouncil(s, councilId);

        if (councilId == DEPLOYER_COUNCIL_ID) {
            if (!council.isGuardian[approver]) revert GZ_Unauthorized();
            RecoveryRequest storage req = s.deployerRecovery;
            if (req.proposed == address(0)) revert GZ_NoRequest();
            if (block.timestamp > req.deadline) revert GZ_Expired();
            if (req.executed) revert GZ_AlreadyApproved();
            if (s.deployerHasApproved[approver]) revert GZ_AlreadyApproved();

            s.deployerHasApproved[approver] = true;
            unchecked { req.approvals++; }
            emit RecoveryApproved(DEPLOYER_COUNCIL_ID, approver, req.approvals);
            return req.approvals;
        }

        if (councilId == ADMIN_COUNCIL_ID) {
            if (!council.isGuardian[approver]) revert GZ_Unauthorized();
            RecoveryRequest storage req2 = s.adminRecovery;
            if (req2.proposed == address(0)) revert GZ_NoRequest();
            if (block.timestamp > req2.deadline) revert GZ_Expired();
            if (req2.executed) revert GZ_AlreadyApproved();
            if (s.adminHasApproved[approver]) revert GZ_AlreadyApproved();

            s.adminHasApproved[approver] = true;
            unchecked { req2.approvals++; }
            emit RecoveryApproved(ADMIN_COUNCIL_ID, approver, req2.approvals);
            return req2.approvals;
        }

        revert GZ_BadParam();
    }

    // ---------------------------
    // Execute recovery
    // ---------------------------
    function executeRecovery(
        Storage storage s,
        bytes32 councilId
    ) internal returns (address) {
        GuardianCouncil storage council = _getCouncil(s, councilId);

        if (councilId == DEPLOYER_COUNCIL_ID) {
            RecoveryRequest storage req = s.deployerRecovery;
            if (req.proposed == address(0)) revert GZ_NoRequest();
            if (block.timestamp > req.deadline) revert GZ_Expired();
            if (req.executed) revert GZ_AlreadyApproved();
            if (req.approvals < council.threshold) revert GZ_ThresholdNotMet();

            // NOTE: original code returned first guardian as "old"
            address old = council.guardians.length > 0 ? council.guardians[0] : address(0);
            address newAddress = req.proposed;
            req.executed = true;

            emit Recovered(DEPLOYER_COUNCIL_ID, old, newAddress);
            return newAddress;
        }

        if (councilId == ADMIN_COUNCIL_ID) {
            RecoveryRequest storage req2 = s.adminRecovery;
            if (req2.proposed == address(0)) revert GZ_NoRequest();
            if (block.timestamp > req2.deadline) revert GZ_Expired();
            if (req2.executed) revert GZ_AlreadyApproved();
            if (req2.approvals < council.threshold) revert GZ_ThresholdNotMet();

            address newAddress = req2.proposed;
            req2.executed = true;
            emit Recovered(ADMIN_COUNCIL_ID, address(0), newAddress);
            return newAddress;
        }

        revert GZ_BadParam();
    }

    // ---------------------------
    // Check guardian
    // ---------------------------
    function isGuardian(Storage storage s, bytes32 councilId, address guardian) internal view returns (bool) {
        GuardianCouncil storage council = _getCouncil(s, councilId);
        return council.isGuardian[guardian];
    }

    // ---------------------------
    // Set guardian at index (swap-out)
    // ---------------------------
    function setGuardian(
        Storage storage s,
        bytes32 councilId,
        uint8 idx,
        address guardian
    ) internal {
        if (guardian == address(0)) revert GZ_ZeroAddress();

        GuardianCouncil storage council = _getCouncil(s, councilId);

        // bounds check
        if (idx >= council.guardians.length) revert GZ_IndexOutOfRange();
        if (council.isGuardian[guardian]) revert GZ_DuplicateGuardian();

        address old = council.guardians[idx];
        if (old != address(0)) {
            council.isGuardian[old] = false;
        }
        council.guardians[idx] = guardian;
        council.isGuardian[guardian] = true;

        emit GuardianSet(councilId, idx, guardian);
    }
}
