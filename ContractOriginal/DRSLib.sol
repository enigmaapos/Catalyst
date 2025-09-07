// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Decentralized Recovery System (guardian council) – pluggable.
library DRSLib {
    // ---- Errors ----
    error NotGuardian();
    error AlreadyApproved();
    error RecoveryLocked();
    error ThresholdNotMet();
    error NotProposer();
    error NotLastHonest();
    error ResetWindowClosed();

    struct Council {
        // council + params
        address[] guardians;
        uint8     threshold; // e.g., 5 (of N)
        uint64    approvalWindowBlocks; // e.g., ~3 days in blocks

        // active proposal
        address   pendingRecovery; // proposed new target
        uint64    startedAtBlock;
        bool      locked;          // auto-lock when full compromise
        mapping(address => bool) approved;
        uint8     approvals;

        // last-honest-guardian reset
        address   lastHonestGuardian;
        uint64    lastHonestWindowEnd; // block height deadline
    }

    event RecoveryProposed(address indexed proposer, address indexed newTarget);
    event RecoveryApproved(address indexed guardian, address indexed newTarget, uint8 approvals);
    event RecoveryLocked(address indexed newTarget);
    event RecoveryExecuted(address indexed newTarget);
    event GuardiansReset(address[] newGuardians, uint8 threshold);

    // ---- Core ----

    function init(Council storage c, address[] memory guardians, uint8 threshold, uint64 approvalWindowBlocks) internal {
        require(threshold > 0 && threshold <= guardians.length, "DRS: bad threshold");
        c.guardians = guardians;
        c.threshold = threshold;
        c.approvalWindowBlocks = approvalWindowBlocks;
    }

    function isGuardian(Council storage c, address a) internal view returns (bool) {
        for (uint256 i = 0; i < c.guardians.length; i++) if (c.guardians[i] == a) return true;
        return false;
    }

    function _clearApprovals(Council storage c) private {
        for (uint256 i = 0; i < c.guardians.length; i++) {
            c.approved[c.guardians[i]] = false;
        }
        c.approvals = 0;
        c.pendingRecovery = address(0);
        c.startedAtBlock = 0;
        c.lastHonestGuardian = address(0);
        c.lastHonestWindowEnd = 0;
    }

    function proposeRecovery(Council storage c, address proposer, address newTarget) internal {
        if (!isGuardian(c, proposer)) revert NotGuardian();
        require(newTarget != address(0), "DRS: zero target");
        require(!c.locked, "DRS: locked");
        _clearApprovals(c);
        c.pendingRecovery = newTarget;
        c.startedAtBlock = uint64(block.number);
        emit RecoveryProposed(proposer, newTarget);
    }

    function approveRecovery(Council storage c, address guardian) internal {
        if (!isGuardian(c, guardian)) revert NotGuardian();
        if (c.locked) revert RecoveryLocked();
        require(c.pendingRecovery != address(0), "DRS: no proposal");
        require(block.number <= c.startedAtBlock + c.approvalWindowBlocks, "DRS: expired");
        if (c.approved[guardian]) revert AlreadyApproved();

        c.approved[guardian] = true;
        c.approvals += 1;

        // Last-honest detection: when approvals = (threshold - 1)
        if (c.approvals == c.threshold - 1) {
            // find who hasn't approved yet
            for (uint256 i = 0; i < c.guardians.length; i++) {
                address g = c.guardians[i];
                if (!c.approved[g]) {
                    c.lastHonestGuardian = g;
                    c.lastHonestWindowEnd = uint64(block.number + (c.approvalWindowBlocks / 2)); // half-window
                    break;
                }
            }
        }

        // Lock if everyone approves (strong signal of compromise)
        if (c.approvals == c.guardians.length) {
            c.locked = true;
            emit RecoveryLocked(c.pendingRecovery);
        }

        emit RecoveryApproved(guardian, c.pendingRecovery, c.approvals);
    }

    /// @notice Execute recovery – caller validated by host contract (e.g., any guardian or the contract itself).
    function executeRecovery(Council storage c, uint8 requiredThreshold) internal returns (address newTarget) {
        require(c.pendingRecovery != address(0), "DRS: no proposal");
        if (c.approvals < requiredThreshold) revert ThresholdNotMet();
        newTarget = c.pendingRecovery;
        _clearApprovals(c);
        emit RecoveryExecuted(newTarget);
    }

    /// @notice Reset guardians by current valid owner (host contract must gate this).
    function ownerResetGuardians(Council storage c, address[] memory newGuardians, uint8 newThreshold) internal {
        require(newThreshold > 0 && newThreshold <= newGuardians.length, "DRS: bad threshold");
        c.guardians = newGuardians;
        c.threshold = newThreshold;
        c.locked = false;
        _clearApprovals(c);
        emit GuardiansReset(newGuardians, newThreshold);
    }

    /// @notice Last honest guardian can reset during its special window.
    function lastHonestResetGuardians(Council storage c, address caller, address[] memory newGuardians, uint8 newThreshold) internal {
        if (caller != c.lastHonestGuardian) revert NotLastHonest();
        if (block.number > c.lastHonestWindowEnd) revert ResetWindowClosed();
        ownerResetGuardians(c, newGuardians, newThreshold);
    }
}
