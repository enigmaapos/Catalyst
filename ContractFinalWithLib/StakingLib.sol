// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title StakingLib
/// @notice Lightweight staking/bookkeeping library for Catalyst.
///         - Supports custodial staking (UNVERIFIED) and non-custodial enrollment (VERIFIED/blue-chip)
///         - Enforces global and per-bucket caps: 1B total (750M term, 250M permanent)
///         - Tracks per-collection caps (default 20,000), stakers and token portfolios
///         - Exposes compact view helpers for UI: global & collection stats
library StakingLib {
    // ------------------------------------------------------------
    // Caps (global)
    // ------------------------------------------------------------
    uint256 public constant GLOBAL_CAP = 1_000_000_000;
    uint256 public constant TERM_CAP   = 750_000_000;
    uint256 public constant PERM_CAP   = 250_000_000;

    // ------------------------------------------------------------
    // Errors (custom to save bytecode vs revert strings)
    // ------------------------------------------------------------
    error GlobalCapReached();
    error TermCapReached();
    error PermCapReached();
    error NotRegistered();
    error AlreadyStaked();
    error NotStaked();
    error TermExpired();
    error OverCollectionCap();

    // ------------------------------------------------------------
    // Tiers / Modes
    // ------------------------------------------------------------
    enum CollectionTier { UNVERIFIED, VERIFIED } // VERIFIED = blue-chip/non-custodial friendly

    // ------------------------------------------------------------
    // Data structures
    // ------------------------------------------------------------
    struct StakeInfo {
        uint256 stakeBlock;
        uint256 lastHarvestBlock;
        bool    currentlyStaked;
        bool    isPermanent;             // false = term
        uint256 unstakeDeadlineBlock;    // used for term; 0 for permanent
    }

    struct CollectionConfig {
        // Counters
        uint256 totalStaked;     // total tokens from this collection currently staked/enrolled
        uint256 totalStakers;    // number of distinct wallets with >=1 active stake in this collection

        // Meta
        bool registered;
        uint256 declaredSupply;

        // Security / policy
        uint256 perCollectionCap;    // default 20_000 unless set on init
        CollectionTier tier;         // UNVERIFIED or VERIFIED (blue-chip)
        bool nonCustodial;           // true for blue-chip style "wallet registration"
    }

    struct Storage {
        // Global counters
        uint256 totalStakedAll;
        uint256 totalStakedTerm;
        uint256 totalStakedPermanent;

        // Per-collection config/metrics
        mapping(address => CollectionConfig) collectionConfigs;

        // Stake logs: collection => owner => tokenId => info
        mapping(address => mapping(address => mapping(uint256 => StakeInfo))) stakeLog;

        // Per-user portfolio within a collection: collection => owner => [tokenIds]
        mapping(address => mapping(address => uint256[])) stakePortfolioByUser;

        // Index of a tokenId in a user's portfolio: collection => owner => tokenId => index
        mapping(address => mapping(address => mapping(uint256 => uint256))) indexOfTokenIdInStakePortfolio;

        // Reward shaping
        uint256 totalStakedNFTsCount;    // global active NFT count (term + perm)
        uint256 baseRewardRate;          // protocol-level reward accumulator
    }

    // ------------------------------------------------------------
    // Events (internal, bubbled by host contract)
    // ------------------------------------------------------------
    event InternalStakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId, bool permanent, bool nonCustodial);
    event InternalUnstakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId);

    // ------------------------------------------------------------
    // Init / Admin helpers (to be called by host contract)
    // ------------------------------------------------------------
    function initCollection(
        Storage storage s,
        address collection,
        uint256 declaredSupply,
        CollectionTier tier,
        bool nonCustodial,
        uint256 perCollectionCap // pass 0 to use default 20,000
    ) internal {
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        cfg.registered = true;
        cfg.declaredSupply = declaredSupply;
        cfg.tier = tier;
        cfg.nonCustodial = nonCustodial;
        cfg.totalStaked = 0;
        cfg.totalStakers = 0;
        cfg.perCollectionCap = perCollectionCap == 0 ? 20_000 : perCollectionCap;
    }

    function setCollectionTier(Storage storage s, address collection, CollectionTier tier, bool nonCustodial)
        internal
    {
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (!cfg.registered) revert NotRegistered();
        cfg.tier = tier;
        cfg.nonCustodial = nonCustodial;
    }

    function setPerCollectionCap(Storage storage s, address collection, uint256 newCap) internal {
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (!cfg.registered) revert NotRegistered();
        cfg.perCollectionCap = newCap;
    }

    // ------------------------------------------------------------
    // Internal core (shared)
    // ------------------------------------------------------------

    /// @dev Shared staking path for both custodial and non-custodial enrollments.
    function _recordStake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 currentBlock,
        bool permanent,
        uint256 termDurationBlocks,
        uint256 rewardRateIncrementPerNFT,
        bool nonCustodialPath // true for VERIFIED/blue-chip "enrollment", false for UNVERIFIED custodial staking
    ) private {
        // Cap checks (global)
        if (s.totalStakedAll + 1 > GLOBAL_CAP) revert GlobalCapReached();
        if (permanent) {
            if (s.totalStakedPermanent + 1 > PERM_CAP) revert PermCapReached();
        } else {
            if (s.totalStakedTerm + 1 > TERM_CAP) revert TermCapReached();
        }

        // Collection checks
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (!cfg.registered) revert NotRegistered();
        if (cfg.totalStaked + 1 > cfg.perCollectionCap) revert OverCollectionCap();

        // Stake record
        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        if (info.currentlyStaked) revert AlreadyStaked();

        info.stakeBlock = currentBlock;
        info.lastHarvestBlock = currentBlock;
        info.currentlyStaked = true;
        info.isPermanent = permanent;
        info.unstakeDeadlineBlock = permanent ? 0 : (currentBlock + termDurationBlocks);

        // Distinct staker accounting (per collection)
        if (s.stakePortfolioByUser[collection][staker].length == 0) {
            cfg.totalStakers += 1;
        }
        cfg.totalStaked += 1;

        // Global accounting
        s.totalStakedNFTsCount += 1;
        s.baseRewardRate += rewardRateIncrementPerNFT;

        // Portfolio indexing
        s.stakePortfolioByUser[collection][staker].push(tokenId);
        s.indexOfTokenIdInStakePortfolio[collection][staker][tokenId] =
            s.stakePortfolioByUser[collection][staker].length - 1;

        // Global bucket counters
        s.totalStakedAll += 1;
        if (permanent) {
            s.totalStakedPermanent += 1;
        } else {
            s.totalStakedTerm += 1;
        }

        emit InternalStakeRecorded(staker, collection, tokenId, permanent, nonCustodialPath);
    }

    /// @dev Shared unstake path for both custodial and non-custodial enrollments.
    function _recordUnstake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 rewardRateDecrementPerNFT
    ) private {
        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        if (!info.currentlyStaked) revert NotStaked();

        // Flip flag first
        info.currentlyStaked = false;

        // Remove from user's portfolio (swap & pop)
        uint256[] storage port = s.stakePortfolioByUser[collection][staker];
        uint256 idx = s.indexOfTokenIdInStakePortfolio[collection][staker][tokenId];
        uint256 last = port.length - 1;
        if (idx != last) {
            uint256 lastTokenId = port[last];
            port[idx] = lastTokenId;
            s.indexOfTokenIdInStakePortfolio[collection][staker][lastTokenId] = idx;
        }
        port.pop();
        delete s.indexOfTokenIdInStakePortfolio[collection][staker][tokenId];

        // Per-collection counters
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (port.length == 0 && cfg.totalStakers > 0) cfg.totalStakers -= 1;
        if (cfg.totalStaked > 0) cfg.totalStaked -= 1;

        // Global reward shaping
        if (s.baseRewardRate >= rewardRateDecrementPerNFT) s.baseRewardRate -= rewardRateDecrementPerNFT;
        if (s.totalStakedNFTsCount > 0) s.totalStakedNFTsCount -= 1;

        // Global bucket counters
        s.totalStakedAll -= 1;
        if (info.isPermanent) {
            s.totalStakedPermanent -= 1;
        } else {
            s.totalStakedTerm -= 1;
        }

        emit InternalUnstakeRecorded(staker, collection, tokenId);
    }

    // ------------------------------------------------------------
    // Custodial staking (UNVERIFIED collections)
    // ------------------------------------------------------------
    function recordTermStake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 currentBlock,
        uint256 termDurationBlocks,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        _recordStake(
            s, collection, staker, tokenId, currentBlock,
            false, termDurationBlocks, rewardRateIncrementPerNFT, /*nonCustodial*/ false
        );
    }

    function recordPermanentStake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 currentBlock,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        _recordStake(
            s, collection, staker, tokenId, currentBlock,
            true, 0, rewardRateIncrementPerNFT, /*nonCustodial*/ false
        );
    }

    // ------------------------------------------------------------
    // Non-custodial enrollment (VERIFIED / blue-chip)
    // NOTE: Host contract must pre-validate actual ERC721 ownership (and keep checking on harvest/claim).
    // ------------------------------------------------------------
    function recordTermEnrollNonCustodial(
        Storage storage s,
        address collection,
        address wallet,
        uint256 tokenId,
        uint256 currentBlock,
        uint256 termDurationBlocks,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        _recordStake(
            s, collection, wallet, tokenId, currentBlock,
            false, termDurationBlocks, rewardRateIncrementPerNFT, /*nonCustodial*/ true
        );
    }

    function recordPermanentEnrollNonCustodial(
        Storage storage s,
        address collection,
        address wallet,
        uint256 tokenId,
        uint256 currentBlock,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        _recordStake(
            s, collection, wallet, tokenId, currentBlock,
            true, 0, rewardRateIncrementPerNFT, /*nonCustodial*/ true
        );
    }

    // ------------------------------------------------------------
    // Unstake (works for both custodial and non-custodial paths)
    // ------------------------------------------------------------
    function recordUnstake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 rewardRateDecrementPerNFT
    ) internal {
        _recordUnstake(s, collection, staker, tokenId, rewardRateDecrementPerNFT);
    }

    // ------------------------------------------------------------
    // Views / helpers
    // ------------------------------------------------------------
    function isStaked(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId
    ) internal view returns (bool) {
        return s.stakeLog[collection][owner][tokenId].currentlyStaked;
    }

    function pendingRewards(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId,
        uint256 numberOfBlocksPerRewardUnit
    ) internal view returns (uint256) {
        StakeInfo memory info = s.stakeLog[collection][owner][tokenId];
        if (!info.currentlyStaked || s.baseRewardRate == 0 || s.totalStakedNFTsCount == 0) return 0;
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) return 0; // expired term -> no rewards

        uint256 blocksPassed = block.number - info.lastHarvestBlock;
        // Proportional share of baseRewardRate over time and active population
        uint256 numerator = blocksPassed * s.baseRewardRate;
        uint256 rewardAmount = (numerator / numberOfBlocksPerRewardUnit) / s.totalStakedNFTsCount;
        return rewardAmount;
    }

    function updateLastHarvest(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId
    ) internal {
        StakeInfo storage info = s.stakeLog[collection][owner][tokenId];
        if (!info.currentlyStaked) revert NotStaked();
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) revert TermExpired();
        info.lastHarvestBlock = block.number;
    }

    // ------------------------------------------------------------
    // Stats (for UI)
    // ------------------------------------------------------------

    /// @notice Global staking stats & remaining capacities
    function stakingStats(Storage storage s)
        internal
        view
        returns (
            uint256 totalAll,
            uint256 totalTerm,
            uint256 totalPerm,
            uint256 leftGlobal,
            uint256 leftTerm,
            uint256 leftPerm
        )
    {
        totalAll  = s.totalStakedAll;
        totalTerm = s.totalStakedTerm;
        totalPerm = s.totalStakedPermanent;
        leftGlobal = GLOBAL_CAP > totalAll ? (GLOBAL_CAP - totalAll) : 0;
        leftTerm   = TERM_CAP   > totalTerm ? (TERM_CAP - totalTerm) : 0;
        leftPerm   = PERM_CAP   > totalPerm ? (PERM_CAP - totalPerm) : 0;
    }

    /// @notice Per-collection stats & remaining capacity
    function collectionStats(Storage storage s, address collection)
        internal
        view
        returns (
            bool registered,
            CollectionTier tier,
            bool nonCustodial,
            uint256 declaredSupply,
            uint256 perCollectionCap,
            uint256 totalStakedInCollection,
            uint256 totalStakersInCollection,
            uint256 leftInCollection
        )
    {
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        registered = cfg.registered;
        tier = cfg.tier;
        nonCustodial = cfg.nonCustodial;
        declaredSupply = cfg.declaredSupply;
        perCollectionCap = cfg.perCollectionCap;
        totalStakedInCollection = cfg.totalStaked;
        totalStakersInCollection = cfg.totalStakers;
        leftInCollection = perCollectionCap > cfg.totalStaked ? (perCollectionCap - cfg.totalStaked) : 0;
    }

    function portfolioLength(Storage storage s, address collection, address owner)
        internal
        view
        returns (uint256)
    {
        return s.stakePortfolioByUser[collection][owner].length;
    }

    function portfolioAt(Storage storage s, address collection, address owner, uint256 index)
        internal
        view
        returns (uint256 tokenId)
    {
        return s.stakePortfolioByUser[collection][owner][index];
    }

    // ------------------------------------------------------------
    // Utils
    // ------------------------------------------------------------
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) {
            z = 1;
        }
    }
}
