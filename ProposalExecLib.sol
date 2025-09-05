// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GovernanceLib.sol";
import "./StakingLib.sol";
import "./ConfigLib.sol";

/// @notice Move the proposal execution ladder into a library to slim main contract.
/// @dev This library mutates StakingLib.Storage, GovernanceLib.Storage, and ConfigLib.Storage.
library ProposalExecLib {
    event ProposalApplied(bytes32 indexed id, GovernanceLib.ProposalType pType, uint256 newValue);

    function applyProposal(
        GovernanceLib.Storage storage g,
        StakingLib.Storage storage s,
        ConfigLib.Storage storage c,
        bytes32 id,
        GovernanceLib.Proposal memory p
    ) internal {
        if (p.pType == GovernanceLib.ProposalType.BASE_REWARD) {
            // Apply base reward with cap
            uint256 cap = ConfigLib.getUint(c, 25); // ✅ explicit call
            uint256 newVal = p.newValue;
            if (cap != 0 && newVal > cap) newVal = cap;
            s.baseRewardRate = newVal;
            emit ProposalApplied(id, p.pType, newVal);

        } else if (p.pType == GovernanceLib.ProposalType.HARVEST_FEE) {
            ConfigLib.setUint(c, 14, p.newValue); // ✅ explicit call
            emit ProposalApplied(id, p.pType, p.newValue);

        } else if (p.pType == GovernanceLib.ProposalType.UNSTAKE_FEE) {
            ConfigLib.setUint(c, 26, p.newValue); // ✅ explicit call
            emit ProposalApplied(id, p.pType, p.newValue);

        } else if (p.pType == GovernanceLib.ProposalType.REGISTRATION_FEE_FALLBACK) {
            ConfigLib.setUint(c, 27, p.newValue); // ✅ explicit call
            emit ProposalApplied(id, p.pType, p.newValue);

        } else if (p.pType == GovernanceLib.ProposalType.VOTING_PARAM) {
            if (p.paramTarget == 0) {
                g.minVotesRequiredScaled = p.newValue;
            } else if (p.paramTarget == 1) {
                g.votingDurationBlocks = p.newValue;
            } else if (p.paramTarget == 2) {
                g.collectionVoteCapPercent = p.newValue;
            } else {
                revert("ProposalExecLib: unknown voting param");
            }
            emit ProposalApplied(id, p.pType, p.newValue);

        } else if (p.pType == GovernanceLib.ProposalType.TIER_UPGRADE) {
            emit ProposalApplied(id, p.pType, p.newValue);

        } else {
            revert("ProposalExecLib: unhandled type");
        }
    }
}
