// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Library for Catalyst protocol config storage & updates.
/// @dev Storage is held in the main contract; this lib provides getters/setters.
///      Param IDs are documented in the set/get functions — use consistent ids.
library ConfigLib {
    struct Storage {
        // Fee brackets
        uint256 smallMinFee;        // paramId 0
        uint256 smallMaxFee;        // paramId 1
        uint256 medMinFee;          // paramId 2
        uint256 medMaxFee;          // paramId 3
        uint256 largeMinFee;        // paramId 4
        uint256 largeMaxFeeCap;     // paramId 5

        // Surcharge
        uint256 unverifiedSurchargeBP; // paramId 6

        // Tier / upgrade rules
        uint256 tierUpgradeMinAgeBlocks;   // paramId 7
        uint256 tierUpgradeMinBurn;        // paramId 8
        uint256 tierUpgradeMinStakers;     // paramId 9
        uint256 tierProposalCooldownBlocks;// paramId 10
        uint256 surchargeForfeitBlocks;    // paramId 11

        // Dynamic params
        uint256 numberOfBlocksPerRewardUnit; // paramId 12
        uint256 collectionRegistrationFee;   // paramId 13
        uint256 initialHarvestBurnFeeRate;   // paramId 14
        uint256 termDurationBlocks;          // paramId 15
        uint256 stakingCooldownBlocks;       // paramId 16
        uint256 harvestRateAdjustmentFactor; // paramId 17
        uint256 minBurnContributionForVote;  // paramId 18

        // Collection / staking behavior
        uint256 initialCollectionFee;            // paramId 19
        uint256 feeMultiplier;                   // paramId 20
        uint256 rewardRateIncrementPerNFT;       // paramId 21
        uint256 welcomeBonusBaseRate;            // paramId 22
        uint256 welcomeBonusIncrementPerNFT;     // paramId 23

        // Governance-related thresholds
        uint256 minStakeAgeForVoting;    // paramId 24
        uint256 maxBaseRewardRate;       // paramId 25

        // Additional param ids used by proposals & core
        uint256 unstakeBurnFee;          // paramId 26
        uint256 registrationFeeFallback; // paramId 27

        // Voting param placeholders (some governance params live in GovernanceLib.Storage,
        // but we include some copies here if you prefer storing centrally)
        // paramId 28..30 reserved for convenience in proposals mapping
        uint256 reserved28;
        uint256 reserved29;
        uint256 reserved30;
    }

    // Events
    event ConfigUintUpdated(uint8 indexed paramId, uint256 oldValue, uint256 newValue);

    /// @notice Set a single uint config by paramId.
    /// @dev paramId mapping defined in struct comments. This keeps the library compact.
    function setUint(Storage storage s, uint8 paramId, uint256 newValue) internal {
        if (paramId == 0) { uint256 old = s.smallMinFee; s.smallMinFee = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 1) { uint256 old = s.smallMaxFee; s.smallMaxFee = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 2) { uint256 old = s.medMinFee; s.medMinFee = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 3) { uint256 old = s.medMaxFee; s.medMaxFee = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 4) { uint256 old = s.largeMinFee; s.largeMinFee = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 5) { uint256 old = s.largeMaxFeeCap; s.largeMaxFeeCap = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 6) { uint256 old = s.unverifiedSurchargeBP; s.unverifiedSurchargeBP = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 7) { uint256 old = s.tierUpgradeMinAgeBlocks; s.tierUpgradeMinAgeBlocks = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 8) { uint256 old = s.tierUpgradeMinBurn; s.tierUpgradeMinBurn = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 9) { uint256 old = s.tierUpgradeMinStakers; s.tierUpgradeMinStakers = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 10) { uint256 old = s.tierProposalCooldownBlocks; s.tierProposalCooldownBlocks = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 11) { uint256 old = s.surchargeForfeitBlocks; s.surchargeForfeitBlocks = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 12) { uint256 old = s.numberOfBlocksPerRewardUnit; s.numberOfBlocksPerRewardUnit = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 13) { uint256 old = s.collectionRegistrationFee; s.collectionRegistrationFee = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 14) { uint256 old = s.initialHarvestBurnFeeRate; s.initialHarvestBurnFeeRate = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 15) { uint256 old = s.termDurationBlocks; s.termDurationBlocks = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 16) { uint256 old = s.stakingCooldownBlocks; s.stakingCooldownBlocks = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 17) { uint256 old = s.harvestRateAdjustmentFactor; s.harvestRateAdjustmentFactor = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 18) { uint256 old = s.minBurnContributionForVote; s.minBurnContributionForVote = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 19) { uint256 old = s.initialCollectionFee; s.initialCollectionFee = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 20) { uint256 old = s.feeMultiplier; s.feeMultiplier = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 21) { uint256 old = s.rewardRateIncrementPerNFT; s.rewardRateIncrementPerNFT = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 22) { uint256 old = s.welcomeBonusBaseRate; s.welcomeBonusBaseRate = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 23) { uint256 old = s.welcomeBonusIncrementPerNFT; s.welcomeBonusIncrementPerNFT = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 24) { uint256 old = s.minStakeAgeForVoting; s.minStakeAgeForVoting = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 25) { uint256 old = s.maxBaseRewardRate; s.maxBaseRewardRate = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 26) { uint256 old = s.unstakeBurnFee; s.unstakeBurnFee = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 27) { uint256 old = s.registrationFeeFallback; s.registrationFeeFallback = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }

        // reserved ids 28..30 for future direct mapping
        if (paramId == 28) { uint256 old = s.reserved28; s.reserved28 = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 29) { uint256 old = s.reserved29; s.reserved29 = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }
        if (paramId == 30) { uint256 old = s.reserved30; s.reserved30 = newValue; emit ConfigUintUpdated(paramId, old, newValue); return; }

        revert("ConfigLib: bad paramId");
    }

    /// @notice Get uint config by paramId.
    function getUint(Storage storage s, uint8 paramId) internal view returns (uint256) {
        if (paramId == 0) return s.smallMinFee;
        if (paramId == 1) return s.smallMaxFee;
        if (paramId == 2) return s.medMinFee;
        if (paramId == 3) return s.medMaxFee;
        if (paramId == 4) return s.largeMinFee;
        if (paramId == 5) return s.largeMaxFeeCap;
        if (paramId == 6) return s.unverifiedSurchargeBP;
        if (paramId == 7) return s.tierUpgradeMinAgeBlocks;
        if (paramId == 8) return s.tierUpgradeMinBurn;
        if (paramId == 9) return s.tierUpgradeMinStakers;
        if (paramId == 10) return s.tierProposalCooldownBlocks;
        if (paramId == 11) return s.surchargeForfeitBlocks;
        if (paramId == 12) return s.numberOfBlocksPerRewardUnit;
        if (paramId == 13) return s.collectionRegistrationFee;
        if (paramId == 14) return s.initialHarvestBurnFeeRate;
        if (paramId == 15) return s.termDurationBlocks;
        if (paramId == 16) return s.stakingCooldownBlocks;
        if (paramId == 17) return s.harvestRateAdjustmentFactor;
        if (paramId == 18) return s.minBurnContributionForVote;
        if (paramId == 19) return s.initialCollectionFee;
        if (paramId == 20) return s.feeMultiplier;
        if (paramId == 21) return s.rewardRateIncrementPerNFT;
        if (paramId == 22) return s.welcomeBonusBaseRate;
        if (paramId == 23) return s.welcomeBonusIncrementPerNFT;
        if (paramId == 24) return s.minStakeAgeForVoting;
        if (paramId == 25) return s.maxBaseRewardRate;
        if (paramId == 26) return s.unstakeBurnFee;
        if (paramId == 27) return s.registrationFeeFallback;
        if (paramId == 28) return s.reserved28;
        if (paramId == 29) return s.reserved29;
        if (paramId == 30) return s.reserved30;

        revert("ConfigLib: bad paramId");
    }
}
