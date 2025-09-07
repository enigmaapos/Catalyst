// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GuardianLib
 * @notice Reusable guardian council with compromise detection, last-honest-guardian reset,
 *         and two independent council "domains" (e.g., GCSS for deployer, AGC for admin).
 */
library GuardianLib {
    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/
    error InvalidGuardians();                  // length/duplicates/zero
    error NotGuardian();                       // caller not guardian
    error AlreadyVoted();                      // guardian voted twice
    error ThresholdNotMet();                   // not enough approvals
    error LockedByFullCompromise();            // 100% approvals => lock
    error NotLastHonestGuardian();             // special reset not allowed
    error WindowExpired();                     // last-honest window expired
    error NoActiveProposal();                  // nothing to execute
    error NotDeployer();                       // for “current deployer only” ops
    error NotAdmin();                          // for “current default admin only” ops

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/
    struct Council {
        // Guardians
        address[7] members;        // fixed 7
        // Recovery proposal
        address proposed;          // new authority (deployer or admin)
        uint8 approvals;           // how many voted yes
        uint8 threshold;           // e.g., 5
        bool[7] hasVoted;          // track votes
        // State flags
        bool locked;               // 7/7 approvals => lock
        // Last-honest-guardian window
        uint64 lastHonestDeadline; // until when the LHG can reset
        uint8 lastHonestIndex;     // who is the not-yet-voting guardian
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/
    function _indexOf(address[7] memory arr, address who) internal pure returns (int8) {
        for (uint8 i = 0; i < 7; i++) {
            if (arr[i] == who) return int8(int256(uint256(i)));
        }
        return -1;
    }

    function _checkDistinct(address[7] memory arr) internal pure returns (bool) {
        for (uint8 i = 0; i < 7; i++) {
            if (arr[i] == address(0)) return false;
            for (uint8 j = i+1; j < 7; j++) {
                if (arr[i] == arr[j]) return false;
            }
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                          COUNCIL LIFECYCLE
    //////////////////////////////////////////////////////////////*/
    function init(
        Council storage c,
        address[7] memory guardians,
        uint8 threshold
    ) internal {
        if (!_checkDistinct(guardians)) revert InvalidGuardians();
        if (threshold == 0 || threshold > 7) revert InvalidGuardians();
        c.members = guardians;
        c.threshold = threshold;
        // zero other fields
    }

    function resetGuardians(
        Council storage c,
        address[7] memory guardians,
        uint8 threshold,
        bool bypassLock // true only when called by the rightful authority
    ) internal {
        if (c.locked && !bypassLock) revert LockedByFullCompromise();
        if (!_checkDistinct(guardians)) revert InvalidGuardians();
        if (threshold == 0 || threshold > 7) revert InvalidGuardians();
        c.members = guardians;
        c.threshold = threshold;
        // clear proposal
        c.proposed = address(0);
        c.approvals = 0;
        for (uint8 i = 0; i < 7; i++) c.hasVoted[i] = false;
        c.locked = false;
        c.lastHonestDeadline = 0;
        c.lastHonestIndex = 0;
    }

    function propose(Council storage c, address newAuthority) internal {
        // start fresh
        c.proposed = newAuthority;
        c.approvals = 0;
        for (uint8 i = 0; i < 7; i++) c.hasVoted[i] = false;
        c.locked = false;
        c.lastHonestDeadline = 0;
        c.lastHonestIndex = 0;
    }

    function approve(
        Council storage c,
        address caller,
        uint64 lhgWindowSeconds
    ) internal returns (uint8 approvals, bool warning, bool locked) {
        int8 idx = _indexOf(c.members, caller);
        if (idx < 0) revert NotGuardian();
        if (c.proposed == address(0)) revert NoActiveProposal();
        if (c.hasVoted[uint8(uint16(uint8(idx)))]) revert AlreadyVoted();

        c.hasVoted[uint8(uint16(uint8(idx)))] = true;
        c.approvals += 1;

        // 6 approvals? => exactly one left = last honest guardian
        if (c.approvals == 6) {
            // find the one who has not yet voted
            for (uint8 i = 0; i < 7; i++) {
                if (!c.hasVoted[i]) {
                    c.lastHonestIndex = i;
                    c.lastHonestDeadline = uint64(block.timestamp) + lhgWindowSeconds;
                    break;
                }
            }
        }

        // full compromise?
        if (c.approvals == 7) {
            c.locked = true;
            return (c.approvals, true, true);
        }

        warning = (c.approvals >= c.threshold - 1); // e.g., 4 of 5, or 4 of 7 if threshold 5
        return (c.approvals, warning, false);
    }

    function execute(Council storage c) internal returns (address newAuthority) {
        if (c.locked) revert LockedByFullCompromise();
        if (c.proposed == address(0)) revert NoActiveProposal();
        if (c.approvals < c.threshold) revert ThresholdNotMet();
        newAuthority = c.proposed;
        // clear proposal (one-shot)
        c.proposed = address(0);
        c.approvals = 0;
        for (uint8 i = 0; i < 7; i++) c.hasVoted[i] = false;
        c.lastHonestDeadline = 0;
        c.lastHonestIndex = 0;
    }

    /// @notice Last-Honest-Guardian reset, allowed only if approvals==6 (one guardian left),
    ///         within the LHG window, by the non-voter.
    function lastHonestReset(
        Council storage c,
        address caller,
        address[7] memory guardians,
        uint8 threshold
    ) internal {
        if (c.approvals != 6) revert ThresholdNotMet();
        if (block.timestamp > c.lastHonestDeadline) revert WindowExpired();
        if (c.members[c.lastHonestIndex] != caller) revert NotLastHonestGuardian();
        resetGuardians(c, guardians, threshold, true);
    }
}
