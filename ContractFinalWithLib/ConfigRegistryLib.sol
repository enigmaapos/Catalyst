// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ConfigRegistryLib
/// @notice Central, upgradeable-friendly registry of protocol parameters.
/// @dev     Values are updated through governance via ProposalExecutorLib -> Core hooks.
///          Reads are cheap view functions the Core can expose.
library ConfigRegistryLib {
    // -------------------- EVENTS --------------------
    event ConfigInitialized();
    event ConfigUpdated(bytes32 indexed key, uint256 oldValue, uint256 newValue);

    // -------------------- STORAGE --------------------
    struct Storage {
        // ---- Fees / Economics (basis points unless noted)
        uint256 harvestBurnBP;              // burn % on harvest (dynamic)
        uint256 unstakeBurnBP;              // burn % on unstake
        uint256 regBaseFee;                 // base registration fee (in CATA wei)
        uint256 regUnverifiedSurchargeBP;   // surcharge for UNVERIFIED (escrow; BP over base)
        uint256 permanentStakeFee;          // flat fee for permanent stake (in CATA wei)

        // ---- Rewards / Emissions
        uint256 blocksPerRewardUnit;        // denominator for reward accrual
        uint256 rewardRateIncrementPerNFT;  // how much baseRewardRate increases per net staked NFT

        // ---- Staking limits
        uint256 perCollectionCap;           // e.g., 20_000 NFTs per collection
        uint256 globalCapAll;               // e.g., 1_000_000_000 NFTs
        uint256 globalCapTerm;              // e.g.,   750_000_000 NFTs
        uint256 globalCapPermanent;         // e.g.,   250_000_000 NFTs

        // ---- Term stake parameters
        uint256 termDurationBlocks;         // lock/eligibility window for term stake

        // ---- Governance parameters
        uint256 quorumBP;                   // min participation (BP of total voting supply)
        uint256 passThresholdBP;            // yes-weight threshold (BP of participating weight)
        uint256 voteWindowBlocks;           // voting window length
        uint256 execGraceBlocks;            // time to execute after voting succeeds

        // ---- Burner bonus program
        uint256 bonusPoolBPOfTreasury;      // <= 500 (5% of treasury per cycle)
        uint256 minBurnForBonus;            // eligibility floor (CATA wei)
        uint256 minStakedForBonus;          // # of NFTs staked required

        // ---- Blue-chip (non-custodial) policy hints (purely informative thresholds)
        uint256 blueChipMinScore;           // arbitrary score/metric gate (if using oracle/off-chain)
        uint256 blueChipMinHolders;         // optional hint
        uint256 blueChipMinAgeBlocks;       // optional hint

        // Internal: guard initialization
        bool    _initialized;
    }

    // -------------------- CONFIG KEYS --------------------
    // NOTE: These are used by governance when calling execConfigUpdates(keys,values).
    bytes32 public constant KEY_HARVEST_BURN_BP              = keccak256("cfg.harvestBurnBP");
    bytes32 public constant KEY_UNSTAKE_BURN_BP              = keccak256("cfg.unstakeBurnBP");
    bytes32 public constant KEY_REG_BASE_FEE                 = keccak256("cfg.regBaseFee");
    bytes32 public constant KEY_REG_UNVERIFIED_SURCHARGE_BP  = keccak256("cfg.regUnverifiedSurchargeBP");
    bytes32 public constant KEY_PERMANENT_STAKE_FEE          = keccak256("cfg.permanentStakeFee");

    bytes32 public constant KEY_BLOCKS_PER_REWARD_UNIT       = keccak256("cfg.blocksPerRewardUnit");
    bytes32 public constant KEY_REWARD_RATE_INC_PER_NFT      = keccak256("cfg.rewardRateIncrementPerNFT");

    bytes32 public constant KEY_PER_COLLECTION_CAP           = keccak256("cfg.perCollectionCap");
    bytes32 public constant KEY_GLOBAL_CAP_ALL               = keccak256("cfg.globalCapAll");
    bytes32 public constant KEY_GLOBAL_CAP_TERM              = keccak256("cfg.globalCapTerm");
    bytes32 public constant KEY_GLOBAL_CAP_PERM              = keccak256("cfg.globalCapPermanent");

    bytes32 public constant KEY_TERM_DURATION_BLOCKS         = keccak256("cfg.termDurationBlocks");

    bytes32 public constant KEY_GOV_QUORUM_BP                = keccak256("cfg.gov.quorumBP");
    bytes32 public constant KEY_GOV_PASS_BP                  = keccak256("cfg.gov.passThresholdBP");
    bytes32 public constant KEY_GOV_VOTE_WINDOW              = keccak256("cfg.gov.voteWindowBlocks");
    bytes32 public constant KEY_GOV_EXEC_GRACE               = keccak256("cfg.gov.execGraceBlocks");

    bytes32 public constant KEY_BONUS_POOL_BP_TREASURY       = keccak256("cfg.bonus.poolBPOfTreasury");
    bytes32 public constant KEY_BONUS_MIN_BURN               = keccak256("cfg.bonus.minBurn");
    bytes32 public constant KEY_BONUS_MIN_STAKED             = keccak256("cfg.bonus.minStaked");

    bytes32 public constant KEY_BC_MIN_SCORE                 = keccak256("cfg.bluechip.minScore");
    bytes32 public constant KEY_BC_MIN_HOLDERS               = keccak256("cfg.bluechip.minHolders");
    bytes32 public constant KEY_BC_MIN_AGE_BLOCKS            = keccak256("cfg.bluechip.minAgeBlocks");

    // -------------------- DEFAULTS --------------------
    function initDefaults(Storage storage s) internal {
        if (s._initialized) return;

        // Fees / economics
        s.harvestBurnBP             = 700;          // 7% burn on harvest (example dynamic)
        s.unstakeBurnBP             = 300;          // 3% burn on unstake
        s.regBaseFee                = 10_000 ether; // example base fee (tune via gov)
        s.regUnverifiedSurchargeBP  = 2_000;        // +20% escrow vs base (refundable on verify)
        s.permanentStakeFee         = 100 ether;    // small one-time fee

        // Rewards
        s.blocksPerRewardUnit       = 6000;         // ~1 day @12s blocks (example)
        s.rewardRateIncrementPerNFT = 1e15;         // tuneable emission curve step

        // Staking limits
        s.perCollectionCap          = 20_000;
        s.globalCapAll              = 1_000_000_000;
        s.globalCapTerm             =   750_000_000;
        s.globalCapPermanent        =   250_000_000;

        // Term stake
        s.termDurationBlocks        = 30 * 6000;    // ~30 days

        // Governance
        s.quorumBP                  = 2000;         // 20% quorum
        s.passThresholdBP           = 5000;         // 50%+ yes
        s.voteWindowBlocks          = 7 * 6000;     // ~1 week
        s.execGraceBlocks           = 7 * 6000;     // ~1 week grace

        // Bonus
        s.bonusPoolBPOfTreasury     = 500;          // 5% of treasury cap per cycle
        s.minBurnForBonus           = 1_000 ether;  // eligibility floor
        s.minStakedForBonus         = 10;           // min NFTs staked

        // Blue-chip hints (optional)
        s.blueChipMinScore          = 80;           // arbitrary scale (0..100+)
        s.blueChipMinHolders        = 1000;
        s.blueChipMinAgeBlocks      = 180 * 6000;   // ~6 months

        s._initialized              = true;
        emit ConfigInitialized();
    }

    // -------------------- UPDATE --------------------
    function setMany(Storage storage s, bytes32[] calldata keys, uint256[] calldata values) internal {
        require(keys.length == values.length, "ConfigRegistry: length");
        for (uint256 i = 0; i < keys.length; i++) {
            _setOne(s, keys[i], values[i]);
        }
    }

    function _setOne(Storage storage s, bytes32 key, uint256 val) private {
        uint256 old;
        if (key == KEY_HARVEST_BURN_BP)                { old = s.harvestBurnBP;                s.harvestBurnBP = val; }
        else if (key == KEY_UNSTAKE_BURN_BP)           { old = s.unstakeBurnBP;                s.unstakeBurnBP = val; }
        else if (key == KEY_REG_BASE_FEE)              { old = s.regBaseFee;                   s.regBaseFee = val; }
        else if (key == KEY_REG_UNVERIFIED_SURCHARGE_BP){ old = s.regUnverifiedSurchargeBP;    s.regUnverifiedSurchargeBP = val; }
        else if (key == KEY_PERMANENT_STAKE_FEE)       { old = s.permanentStakeFee;            s.permanentStakeFee = val; }

        else if (key == KEY_BLOCKS_PER_REWARD_UNIT)    { old = s.blocksPerRewardUnit;          s.blocksPerRewardUnit = val; }
        else if (key == KEY_REWARD_RATE_INC_PER_NFT)   { old = s.rewardRateIncrementPerNFT;    s.rewardRateIncrementPerNFT = val; }

        else if (key == KEY_PER_COLLECTION_CAP)        { old = s.perCollectionCap;             s.perCollectionCap = val; }
        else if (key == KEY_GLOBAL_CAP_ALL)            { old = s.globalCapAll;                 s.globalCapAll = val; }
        else if (key == KEY_GLOBAL_CAP_TERM)           { old = s.globalCapTerm;                s.globalCapTerm = val; }
        else if (key == KEY_GLOBAL_CAP_PERM)           { old = s.globalCapPermanent;           s.globalCapPermanent = val; }

        else if (key == KEY_TERM_DURATION_BLOCKS)      { old = s.termDurationBlocks;           s.termDurationBlocks = val; }

        else if (key == KEY_GOV_QUORUM_BP)             { old = s.quorumBP;                     s.quorumBP = val; }
        else if (key == KEY_GOV_PASS_BP)               { old = s.passThresholdBP;              s.passThresholdBP = val; }
        else if (key == KEY_GOV_VOTE_WINDOW)           { old = s.voteWindowBlocks;             s.voteWindowBlocks = val; }
        else if (key == KEY_GOV_EXEC_GRACE)            { old = s.execGraceBlocks;              s.execGraceBlocks = val; }

        else if (key == KEY_BONUS_POOL_BP_TREASURY)    { old = s.bonusPoolBPOfTreasury;        require(val <= 500, "ConfigRegistry: >5%"); s.bonusPoolBPOfTreasury = val; }
        else if (key == KEY_BONUS_MIN_BURN)            { old = s.minBurnForBonus;              s.minBurnForBonus = val; }
        else if (key == KEY_BONUS_MIN_STAKED)          { old = s.minStakedForBonus;            s.minStakedForBonus = val; }

        else if (key == KEY_BC_MIN_SCORE)              { old = s.blueChipMinScore;             s.blueChipMinScore = val; }
        else if (key == KEY_BC_MIN_HOLDERS)            { old = s.blueChipMinHolders;           s.blueChipMinHolders = val; }
        else if (key == KEY_BC_MIN_AGE_BLOCKS)         { old = s.blueChipMinAgeBlocks;         s.blueChipMinAgeBlocks = val; }
        else {
            revert("ConfigRegistry: unknown key");
        }

        emit ConfigUpdated(key, old, val);
    }

    // -------------------- READ HELPERS --------------------
    function stakingCaps(Storage storage s) internal view returns (uint256 perCollection, uint256 capAll, uint256 capTerm, uint256 capPerm) {
        return (s.perCollectionCap, s.globalCapAll, s.globalCapTerm, s.globalCapPermanent);
    }

    function feeParams(Storage storage s) internal view returns (
        uint256 harvestBP, uint256 unstakeBP, uint256 regBase, uint256 regSurchargeBP, uint256 permFee
    ) {
        return (s.harvestBurnBP, s.unstakeBurnBP, s.regBaseFee, s.regUnverifiedSurchargeBP, s.permanentStakeFee);
    }

    function rewardParams(Storage storage s) internal view returns (uint256 blocksPerUnit, uint256 incPerNFT) {
        return (s.blocksPerRewardUnit, s.rewardRateIncrementPerNFT);
    }

    function termParams(Storage storage s) internal view returns (uint256 durationBlocks) {
        return s.termDurationBlocks;
    }

    function governanceParams(Storage storage s) internal view returns (uint256 quorum, uint256 pass, uint256 voteWindow, uint256 execGrace) {
        return (s.quorumBP, s.passThresholdBP, s.voteWindowBlocks, s.execGraceBlocks);
    }

    function bonusParams(Storage storage s) internal view returns (uint256 poolBP, uint256 minBurn, uint256 minStaked) {
        return (s.bonusPoolBPOfTreasury, s.minBurnForBonus, s.minStakedForBonus);
    }

    function blueChipHints(Storage storage s) internal view returns (uint256 minScore, uint256 minHolders, uint256 minAgeBlocks) {
        return (s.blueChipMinScore, s.blueChipMinHolders, s.blueChipMinAgeBlocks);
    }
}
