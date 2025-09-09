// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GuardianLib
 * @notice Guardian councils (Deployer/Admin), duplicate-proof setup, replacement, and 7-of-5 recovery.
 *         All heavy logic + guards live here to reduce main contract bytecode size.
 *
 * Councils:
 *  - COUNCIL_DEPLOYER: recovers `deployerAddress`
 *  - COUNCIL_ADMIN:    recovers DEFAULT_ADMIN_ROLE control (main contract grants the role)
 *
 * How to use (in your main contract):
 *  - keep your own `address deployerAddress;`
 *  - keep your own DEFAULT_ADMIN_ROLE via OZ
 *  - store a single GuardianLib.Storage `guard;`
 *  - delegate to the library for council management + recovery checks
 *
 * Gas/size notes:
 *  - We emit events *inside* the library where possible to reduce main bytecode.
 *  - The main contract only performs the final state mutation (set deployer/grant role).
 */
library GuardianLib {
    /*------------------------*
     *          ERRORS        *
     *------------------------*/
    error ZeroAddress();
    error BadParam();
    error Unauthorized();
    error NoRequest();
    error Expired();
    error AlreadyApproved();
    error Threshold();
    error DuplicateGuardian();

    /*------------------------*
     *          EVENTS        *
     *------------------------*/
    event GuardianSet(bytes32 indexed council, uint8 idx, address guardian);
    event RecoveryProposed(bytes32 indexed council, address indexed proposer, address proposed, uint256 deadline);
    event RecoveryApproved(bytes32 indexed council, address indexed guardian, uint8 approvals);

    /*------------------------*
     *        CONSTANTS       *
     *------------------------*/
    bytes32 internal constant COUNCIL_DEPLOYER = keccak256("DEPLOYER");
    bytes32 internal constant COUNCIL_ADMIN    = keccak256("ADMIN");

    /*------------------------*
     *         STORAGE        *
     *------------------------*/
    struct RecoveryRequest {
        address proposed;
        uint8 approvals;
        uint64 deadline;   // enough for timestamps
        bool executed;
    }

    struct Council {
        address[] guardians;               // dynamic (7 expected)
        mapping(address => bool) isGuardian;
        mapping(address => bool) hasApproved;
        uint8 threshold;                    // 5 expected
    }

    struct Storage {
        // councils
        Council deployerCouncil;
        Council adminCouncil;

        // pending recoveries
        RecoveryRequest deployerRecovery;
        RecoveryRequest adminRecovery;

        // recovery params
        uint32 recoveryWindow; // seconds (3 days typical)
    }

    /*------------------------*
     *      INTERNAL HELP     *
     *------------------------*/
    function _council(Storage storage s, bytes32 councilId)
        private
        view
        returns (Council storage c)
    {
        if (councilId == COUNCIL_DEPLOYER) return s.deployerCouncil;
        if (councilId == COUNCIL_ADMIN)    return s.adminCouncil;
        revert BadParam();
    }

    function _recovery(Storage storage s, bytes32 councilId)
        private
        view
        returns (RecoveryRequest storage r)
    {
        if (councilId == COUNCIL_DEPLOYER) return s.deployerRecovery;
        if (councilId == COUNCIL_ADMIN)    return s.adminRecovery;
        revert BadParam();
    }

    /*------------------------*
     *        INITIALIZE      *
     *------------------------*/
    /**
     * @dev Initializes both councils with duplicate/zero checks and sets thresholds & recovery window.
     *
     * @param s                 Guardian storage slot
     * @param deployerGuardians list of deployer guardians (length can be 0..N; usually 7)
     * @param adminGuardians    list of admin guardians    (length can be 0..N; usually 7)
     * @param deployerThreshold approvals required (e.g., 5)
     * @param adminThreshold    approvals required (e.g., 5)
     * @param recoveryWindow    seconds window (e.g., 3 days)
     */
    function init(
        Storage storage s,
        address[] memory deployerGuardians,
        address[] memory adminGuardians,
        uint8 deployerThreshold,
        uint8 adminThreshold,
        uint32 recoveryWindow
    ) internal {
        if (deployerThreshold == 0 || adminThreshold == 0) revert BadParam();
        if (recoveryWindow == 0) revert BadParam();

        // Deployer council
        _seedCouncil(s.deployerCouncil, COUNCIL_DEPLOYER, deployerGuardians, deployerThreshold);

        // Admin council
        _seedCouncil(s.adminCouncil, COUNCIL_ADMIN, adminGuardians, adminThreshold);

        s.recoveryWindow = recoveryWindow;
    }

    function _seedCouncil(
        Council storage c,
        bytes32 councilId,
        address[] memory guardians,
        uint8 threshold
    ) private {
        // duplicate and zero checks; push into dynamic array
        uint256 n = guardians.length;
        c.threshold = threshold;

        for (uint256 i = 0; i < n; ++i) {
            address g = guardians[i];
            if (g == address(0)) revert ZeroAddress();
            if (c.isGuardian[g]) revert DuplicateGuardian();
            c.guardians.push(g);
            c.isGuardian[g] = true;
            emit GuardianSet(councilId, uint8(i), g);
        }

        // threshold must not exceed guardian count (and non-zero checked earlier)
        if (threshold > n) revert BadParam();
    }

    /*------------------------*
     *     COUNCIL MGMT       *
     *------------------------*/
    /**
     * @dev Replace or append a guardian at `idx` (append allowed when idx==length).
     * Duplicate/zero guarded. Emits event.
     */
    function setGuardian(
        Storage storage s,
        bytes32 councilId,
        uint8 idx,
        address guardian
    ) internal {
        if (guardian == address(0)) revert ZeroAddress();
        Council storage c = _council(s, councilId);

        // duplicate guard
        if (c.isGuardian[guardian]) revert DuplicateGuardian();

        uint256 n = c.guardians.length;

        if (idx > n) revert BadParam();

        if (idx == n) {
            // append
            c.guardians.push(guardian);
        } else {
            // replace
            address old = c.guardians[idx];
            if (old != address(0)) c.isGuardian[old] = false;
            c.guardians[idx] = guardian;
        }
        c.isGuardian[guardian] = true;

        // keep threshold sane
        if (c.threshold == 0 || c.threshold > c.guardians.length) revert BadParam();

        emit GuardianSet(councilId, idx, guardian);
    }

    function isGuardian(Storage storage s, bytes32 councilId, address who) internal view returns (bool) {
        return _council(s, councilId).isGuardian[who];
    }

    /*------------------------*
     *     RECOVERY FLOW      *
     *------------------------*/
    function proposeRecovery(
        Storage storage s,
        bytes32 councilId,
        address proposer,
        address proposed,
        uint64 nowTs
    ) internal {
        if (!isGuardian(s, councilId, proposer)) revert Unauthorized();
        if (proposed == address(0)) revert ZeroAddress();

        RecoveryRequest storage r = _recovery(s, councilId);

        r.proposed  = proposed;
        r.approvals = 0;
        r.deadline  = nowTs + s.recoveryWindow;
        r.executed  = false;

        // reset approvals for current guardians
        Council storage c = _council(s, councilId);
        uint256 n = c.guardians.length;
        for (uint256 i = 0; i < n; ++i) {
            address g = c.guardians[i];
            if (g != address(0)) c.hasApproved[g] = false;
        }

        emit RecoveryProposed(councilId, proposer, proposed, r.deadline);
    }

    function approveRecovery(
        Storage storage s,
        bytes32 councilId,
        address approver,
        uint64 nowTs
    ) internal {
        if (!isGuardian(s, councilId, approver)) revert Unauthorized();

        RecoveryRequest storage r = _recovery(s, councilId);
        if (r.proposed == address(0)) revert NoRequest();
        if (nowTs > r.deadline) revert Expired();
        if (r.executed) revert AlreadyApproved();

        Council storage c = _council(s, councilId);
        if (c.hasApproved[approver]) revert AlreadyApproved();

        c.hasApproved[approver] = true;
        r.approvals += 1;

        emit RecoveryApproved(councilId, approver, r.approvals);
    }

    /**
     * @dev Validates the recovery for a council and marks it executed. Returns the proposed address.
     * The caller (main contract) must then:
     *  - For COUNCIL_DEPLOYER: set `deployerAddress` and emit its own event.
     *  - For COUNCIL_ADMIN:    grant DEFAULT_ADMIN_ROLE and emit its own event.
     */
    function finalizeRecovery(
        Storage storage s,
        bytes32 councilId,
        uint64 nowTs
    ) internal returns (address proposed) {
        RecoveryRequest storage r = _recovery(s, councilId);
        Council storage c = _council(s, councilId);

        if (r.proposed == address(0)) revert NoRequest();
        if (nowTs > r.deadline) revert Expired();
        if (r.executed) revert AlreadyApproved();
        if (r.approvals < c.threshold) revert Threshold();

        r.executed = true;
        proposed = r.proposed;
    }
}
