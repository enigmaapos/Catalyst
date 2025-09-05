// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GovernanceLib.sol";
import "./StakingLib.sol";
import "./ConfigLib.sol";

/// @notice Move the proposal execution ladder into a library to slim main contract.
/// @dev This library mutates StakingLib.Storage, GovernanceLib.Storage, and ConfigLib.Storage.
library ProposalExecLib {
    using ConfigLib for ConfigLib.Storage;   // ✅ Fix: attach library
    using StakingLib for StakingLib.Storage; // (optional if calling StakingLib methods)
    using GovernanceLib for GovernanceLib.Storage; // (optional if calling GovernanceLib methods)

    event ProposalApplied(bytes32 indexed id, GovernanceLib.ProposalType pType, uint256 newValue);

    /// @notice Apply a validated proposal to the relevant storage.
    /// @param g governance storage (will be mutated for voting params when required)
    /// @param s staking storage (for base reward updates)
    /// @param c config storage (for fees and registration fallback etc.)
    /// @param id proposal id (used only for event)
    /// @param p the validated proposal (should already be validated by GovernanceLib.validateForExecution)
    function applyProposal(
        GovernanceLib.Storage storage g,
        StakingLib.Storage storage s,
        ConfigLib.Storage storage c,
        bytes32 id,
        GovernanceLib.Proposal memory p
    ) internal {
        if (p.pType == GovernanceLib.ProposalType.BASE_REWARD) {
            // Apply base reward with cap
            uint256 cap = c.getUint(25); // paramId 25 = maxBaseRewardRate
            uint256 newVal = p.newValue;
            if (cap != 0 && newVal > cap) newVal = cap;
            s.baseRewardRate = newVal;
            emit ProposalApplied(id, p.pType, newVal);

        } else if (p.pType == GovernanceLib.ProposalType.HARVEST_FEE) {
            // set initial harvest burn fee in config (paramId 14)
            c.setUint(14, p.newValue);
            emit ProposalApplied(id, p.pType, p.newValue);

        } else if (p.pType == GovernanceLib.ProposalType.UNSTAKE_FEE) {
            // move unstake fee into config (paramId 26)
            c.setUint(26, p.newValue);
            emit ProposalApplied(id, p.pType, p.newValue);

        } else if (p.pType == GovernanceLib.ProposalType.REGISTRATION_FEE_FALLBACK) {
            // update registration fallback (paramId 27)
            c.setUint(27, p.newValue);
            emit ProposalApplied(id, p.pType, p.newValue);

        } else if (p.pType == GovernanceLib.ProposalType.VOTING_PARAM) {
            // paramTarget mapping:
            // 0 => minVotesRequiredScaled
            // 1 => votingDurationBlocks
            // 2 => collectionVoteCapPercent
            uint8 t = p.paramTarget;
            if (t == 0) {
                g.minVotesRequiredScaled = p.newValue;
            } else if (t == 1) {
                g.votingDurationBlocks = p.newValue;
            } else if (t == 2) {
                g.collectionVoteCapPercent = p.newValue;
            } else {
                revert("ProposalExecLib: unknown voting param");
            }
            emit ProposalApplied(id, p.pType, p.newValue);

        } else if (p.pType == GovernanceLib.ProposalType.TIER_UPGRADE) {
            // Tier upgrades might be handled off-chain or by a special flow — here we simply emit.
            emit ProposalApplied(id, p.pType, p.newValue);

        } else {
            revert("ProposalExecLib: unhandled type");
        }
    }
}
