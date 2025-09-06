// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GuardianLib
/// @notice Shared guardian voting/recovery logic with add/remove/reset
library GuardianLib {
    error NotGuardian();
    error AlreadyVoted();
    error RecoveryExpired();
    error RecoveryNotMet();
    error RecoveryAlreadyExecuted();
    error InvalidAddress();
    error IndexOutOfBounds();

    struct RecoveryRequest {
        address proposed;
        uint8 approvals;
        uint256 deadline;
        bool executed;
    }

    struct GuardianCouncil {
        address[] guardians;
        mapping(address => bool) isGuardian;
        mapping(address => bool) hasApproved;
        RecoveryRequest active;
        uint8 threshold;
        uint256 recoveryWindow;
    }

    event GuardianSet(uint8 indexed index, address guardian);
    event GuardianAdded(address guardian);
    event GuardianRemoved(address guardian);
    event GuardiansReset(address[] newGuardians);
    event RecoveryProposed(address proposed, uint256 deadline);
    event RecoveryApproved(address guardian, uint8 approvals);
    event RecoveryExecuted(address oldAddr, address newAddr);

    modifier onlyGuardian(GuardianCouncil storage c) {
        if (!c.isGuardian[msg.sender]) revert NotGuardian();
        _;
    }

    // ---- Init ----
    function init(
        GuardianCouncil storage c,
        address[] calldata guardians,
        uint8 threshold,
        uint256 recoveryWindow
    ) internal {
        require(threshold <= guardians.length, "bad threshold");
        c.threshold = threshold;
        c.recoveryWindow = recoveryWindow;
        for (uint8 i = 0; i < guardians.length; i++) {
            _setGuardian(c, i, guardians[i]);
        }
    }

    // ---- Guardian Management ----
    function _setGuardian(
        GuardianCouncil storage c,
        uint8 index,
        address g
    ) internal {
        if (g == address(0)) revert InvalidAddress();
        if (index < c.guardians.length) {
            address old = c.guardians[index];
            if (old != address(0)) c.isGuardian[old] = false;
            c.guardians[index] = g;
        } else {
            c.guardians.push(g);
        }
        c.isGuardian[g] = true;
        emit GuardianSet(index, g);
    }

    function addGuardian(GuardianCouncil storage c, address g) internal {
        if (g == address(0)) revert InvalidAddress();
        if (c.isGuardian[g]) return;
        c.guardians.push(g);
        c.isGuardian[g] = true;
        emit GuardianAdded(g);
    }

    function removeGuardian(GuardianCouncil storage c, address g) internal {
        if (!c.isGuardian[g]) return;
        c.isGuardian[g] = false;

        for (uint8 i = 0; i < c.guardians.length; i++) {
            if (c.guardians[i] == g) {
                c.guardians[i] = c.guardians[c.guardians.length - 1];
                c.guardians.pop();
                break;
            }
        }
        emit GuardianRemoved(g);
    }

    function resetGuardians(
        GuardianCouncil storage c,
        address[] calldata newGuardians,
        uint8 newThreshold
    ) internal {
        require(newThreshold <= newGuardians.length, "bad threshold");

        // clear old
        for (uint8 i = 0; i < c.guardians.length; i++) {
            c.isGuardian[c.guardians[i]] = false;
        }
        delete c.guardians;

        // set new
        for (uint8 j = 0; j < newGuardians.length; j++) {
            address g = newGuardians[j];
            if (g == address(0)) revert InvalidAddress();
            c.guardians.push(g);
            c.isGuardian[g] = true;
        }

        c.threshold = newThreshold;
        emit GuardiansReset(newGuardians);
    }

    // ---- Recovery ----
    function proposeRecovery(
        GuardianCouncil storage c,
        address newAddr
    ) internal onlyGuardian(c) {
        if (newAddr == address(0)) revert InvalidAddress();

        c.active = RecoveryRequest({
            proposed: newAddr,
            approvals: 0,
            deadline: block.timestamp + c.recoveryWindow,
            executed: false
        });

        // clear approvals
        for (uint8 i = 0; i < c.guardians.length; i++) {
            c.hasApproved[c.guardians[i]] = false;
        }

        emit RecoveryProposed(newAddr, c.active.deadline);
    }

    function approveRecovery(GuardianCouncil storage c)
        internal
        onlyGuardian(c)
    {
        if (c.active.executed) revert RecoveryAlreadyExecuted();
        if (block.timestamp > c.active.deadline) revert RecoveryExpired();
        if (c.hasApproved[msg.sender]) revert AlreadyVoted();

        c.hasApproved[msg.sender] = true;
        c.active.approvals++;
        emit RecoveryApproved(msg.sender, c.active.approvals);
    }

    function canExecute(GuardianCouncil storage c) internal view returns (bool) {
        return (!c.active.executed &&
            block.timestamp <= c.active.deadline &&
            c.active.approvals >= c.threshold);
    }

    function markExecuted(GuardianCouncil storage c) internal {
        if (c.active.executed) revert RecoveryAlreadyExecuted();
        if (!canExecute(c)) revert RecoveryNotMet();
        c.active.executed = true;
    }

    // ---- Views ----
    function guardians(GuardianCouncil storage c) internal view returns (address[] memory) {
        return c.guardians;
    }
}
