// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GuardianLib
/// @notice Shared guardian voting/recovery logic
library GuardianLib {
    error NotGuardian();
    error AlreadyVoted();
    error RecoveryExpired();
    error RecoveryNotMet();
    error RecoveryAlreadyExecuted();
    error InvalidAddress();

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
    event RecoveryProposed(address proposed, uint256 deadline);
    event RecoveryApproved(address guardian, uint8 approvals);
    event RecoveryExecuted(address oldAddr, address newAddr);

    modifier onlyGuardian(GuardianCouncil storage c) {
        if (!c.isGuardian[msg.sender]) revert NotGuardian();
        _;
    }

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

        // clear votes
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

    function guardians(GuardianCouncil storage c) internal view returns (address[] memory) {
        return c.guardians;
    }
}
