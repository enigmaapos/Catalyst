// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Lightweight staking + blue-chip registration library (bookkeeping only).
library StakingLib {
    // ----------------------------- //
    //             CAPS              //
    // ----------------------------- //
    uint256 public constant GLOBAL_CAP = 1_000_000_000;
    uint256 public constant TERM_CAP   = 750_000_000;  // 75%
    uint256 public constant PERM_CAP   = 250_000_000;  // 25%

    // ----------------------------- //
    //            ERRORS             //
    // ----------------------------- //
    error GlobalCapReached();
    error TermCapReached();
    error PermCapReached();
    error NotRegisteredCollection();
    error AlreadyStaked();
    error NotStaked();

    // ----------------------------- //
    //            TYPES              //
    // ----------------------------- //
    struct StakeInfo {
        uint256 stakeBlock;
        uint256 lastHarvestBlock;
        bool    currentlyStaked;
        bool    isPermanent;
        uint256 unstakeDeadlineBlock; // 0 for permanent
    }

    struct CollectionConfig {
        uint256 totalStaked;   // custodial stakes in this collection
        uint256 totalStakers;  // unique custodial stakers
        bool    registered;    // collection registered in protocol
        uint256 declaredSupply;
    }

    struct Storage {
        // -------- Custodial stake counters --------
        uint256 totalStakedAll;        // custodial + blue-chip “virtual”
        uint256 totalStakedTerm;       // custodial + blue-chip “virtual” (term)
        uint256 totalStakedPermanent;  // custodial + blue-chip “virtual” (permanent)

        // Per-collection configs (only needed for custodial stake tracking)
        mapping(address => CollectionConfig) collectionConfigs;

        // Custodial stake logs: collection => staker => tokenId => info
        mapping(address => mapping(address => mapping(uint256 => StakeInfo))) stakeLog;

        // Portfolios (custodial): collection => staker => tokenIds[]
        mapping(address => mapping(address => uint256[])) stakePortfolioByUser;

        // Index map for O(1) removal: collection => staker => tokenId => index
        mapping(address => mapping(address => mapping(uint256 => uint256))) indexOfTokenIdInStakePortfolio;

        // Global reward accounting helpers (shared pool concept)
        uint256 totalStakedNFTsCount;  // custodial count only (for your pool math); keep as-is
        uint256 baseRewardRate;

        // -------- Blue-chip (non-custodial) registration counters --------
        // Optional stats for UI / analytics. These DO NOT track tokenIds, just counts.
        uint256 totalBlueChipRegistered;                                // global count (term + permanent)
        mapping(address => uint256) blueChipRegisteredPerCollection;    // by collection
        mapping(address => mapping(address => uint256)) blueChipRegisteredPerUser; // collection => user => count
    }

    // ----------------------------- //
    //            EVENTS             //
    // ----------------------------- //
    event InternalStakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event InternalUnstakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId);

    // Blue-chip events (count-based, since there’s no token custody)
    event BlueChipRegistered(address indexed collection, address indexed user, uint256 count, bool isPermanent);
    event BlueChipDeregistered(address indexed collection, address indexed user, uint256 count, bool wasPermanent);

    // ----------------------------- //
    //        COLLECTION ADMIN       //
    // ----------------------------- //
    function initCollection(Storage storage s, address collection, uint256 declaredSupply) internal {
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        cfg.declaredSupply = declaredSupply;
        cfg.registered = true;
        cfg.totalStaked = 0;
        cfg.totalStakers = 0;
    }

    // ----------------------------- //
    //        CUSTODIAL STAKING      //
    // ----------------------------- //
    function recordTermStake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 currentBlock,
        uint256 termDurationBlocks,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        // Cap checks for TERM
        if (s.totalStakedAll + 1 > GLOBAL_CAP) revert GlobalCapReached();
        if (s.totalStakedTerm + 1 > TERM_CAP) revert TermCapReached();

        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (!cfg.registered) revert NotRegisteredCollection();

        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        if (info.currentlyStaked) revert AlreadyStaked();

        info.stakeBlock = currentBlock;
        info.lastHarvestBlock = currentBlock;
        info.currentlyStaked = true;
        info.isPermanent = false;
        info.unstakeDeadlineBlock = currentBlock + termDurationBlocks;

        if (s.stakePortfolioByUser[collection][staker].length == 0) cfg.totalStakers += 1;
        cfg.totalStaked += 1;

        s.totalStakedNFTsCount += 1;               // custodial-only pool sizing (keep your existing math)
        s.baseRewardRate += rewardRateIncrementPerNFT;

        s.stakePortfolioByUser[collection][staker].push(tokenId);
        s.indexOfTokenIdInStakePortfolio[collection][staker][tokenId] =
            s.stakePortfolioByUser[collection][staker].length - 1;

        // Global counters (custodial contribute to global + term)
        s.totalStakedAll += 1;
        s.totalStakedTerm += 1;

        emit InternalStakeRecorded(staker, collection, tokenId);
    }

    function recordPermanentStake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 currentBlock,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        // Cap checks for PERMANENT
        if (s.totalStakedAll + 1 > GLOBAL_CAP) revert GlobalCapReached();
        if (s.totalStakedPermanent + 1 > PERM_CAP) revert PermCapReached();

        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (!cfg.registered) revert NotRegisteredCollection();

        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        if (info.currentlyStaked) revert AlreadyStaked();

        info.stakeBlock = currentBlock;
        info.lastHarvestBlock = currentBlock;
        info.currentlyStaked = true;
        info.isPermanent = true;
        info.unstakeDeadlineBlock = 0;

        if (s.stakePortfolioByUser[collection][staker].length == 0) cfg.totalStakers += 1;
        cfg.totalStaked += 1;

        s.totalStakedNFTsCount += 1;               // custodial-only pool sizing (keep your existing math)
        s.baseRewardRate += rewardRateIncrementPerNFT;

        s.stakePortfolioByUser[collection][staker].push(tokenId);
        s.indexOfTokenIdInStakePortfolio[collection][staker][tokenId] =
            s.stakePortfolioByUser[collection][staker].length - 1;

        // Global counters (custodial contribute to global + permanent)
        s.totalStakedAll += 1;
        s.totalStakedPermanent += 1;

        emit InternalStakeRecorded(staker, collection, tokenId);
    }

    function recordUnstake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        if (!info.currentlyStaked) revert NotStaked();

        info.currentlyStaked = false;

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

        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (port.length == 0 && cfg.totalStakers > 0) cfg.totalStakers -= 1;
        if (cfg.totalStaked > 0) cfg.totalStaked -= 1;

        // Keep your shared-pool math consistent with custodial stakes only
        if (s.baseRewardRate >= rewardRateIncrementPerNFT) s.baseRewardRate -= rewardRateIncrementPerNFT;
        if (s.totalStakedNFTsCount > 0) s.totalStakedNFTsCount -= 1;

        // Decrement global counters based on type
        s.totalStakedAll -= 1;
        if (info.isPermanent) {
            s.totalStakedPermanent -= 1;
        } else {
            s.totalStakedTerm -= 1;
        }

        emit InternalUnstakeRecorded(staker, collection, tokenId);
    }

    // ----------------------------- //
    //     BLUE-CHIP REGISTRATION    //
    // ----------------------------- //
    /// @notice Count-based “virtual staking” for high-value/blue-chip collections (non-custodial).
    /// Core contract must perform all ownership proofs, collection flags, fee logic, and cap checks before calling.
    function addBlueChip(
        Storage storage s,
        address collection,
        address user,
        uint256 count,
        bool isPermanent
    ) internal {
        // Global caps (count-based)
        if (s.totalStakedAll + count > GLOBAL_CAP) revert GlobalCapReached();
        if (isPermanent) {
            if (s.totalStakedPermanent + count > PERM_CAP) revert PermCapReached();
            s.totalStakedPermanent += count;
        } else {
            if (s.totalStakedTerm + count > TERM_CAP) revert TermCapReached();
            s.totalStakedTerm += count;
        }

        s.totalStakedAll += count;

        // Optional analytics counters
        s.totalBlueChipRegistered += count;
        s.blueChipRegisteredPerCollection[collection] += count;
        s.blueChipRegisteredPerUser[collection][user] += count;

        emit BlueChipRegistered(collection, user, count, isPermanent);
    }

    /// @notice Reverse blue-chip registration (e.g., holder sells or opts out).
    /// Core must validate that `count` does not underflow per-user/per-collection counters.
    function removeBlueChip(
        Storage storage s,
        address collection,
        address user,
        uint256 count,
        bool wasPermanent
    ) internal {
        // Adjust global buckets
        s.totalStakedAll -= count;
        if (wasPermanent) {
            s.totalStakedPermanent -= count;
        } else {
            s.totalStakedTerm -= count;
        }

        // Optional analytics counters
        s.totalBlueChipRegistered -= count;
        s.blueChipRegisteredPerCollection[collection] -= count;
        s.blueChipRegisteredPerUser[collection][user] -= count;

        emit BlueChipDeregistered(collection, user, count, wasPermanent);
    }

    // ----------------------------- //
    //         VIEW HELPERS          //
    // ----------------------------- //
    /// @notice Pending rewards for *custodial* stakes only (blue-chip regs are count-based; your core decides rewards).
    function pendingRewards(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId,
        uint256 numberOfBlocksPerRewardUnit
    ) internal view returns (uint256) {
        StakeInfo memory info = s.stakeLog[collection][owner][tokenId];
        if (!info.currentlyStaked || s.baseRewardRate == 0 || s.totalStakedNFTsCount == 0) return 0;
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) return 0;

        uint256 blocksPassed = block.number - info.lastHarvestBlock;
        uint256 numerator = blocksPassed * s.baseRewardRate;
        // NOTE: You kept shared pool math based on custodial-only `totalStakedNFTsCount`
        uint256 rewardAmount = (numerator / numberOfBlocksPerRewardUnit) / s.totalStakedNFTsCount;
        return rewardAmount;
    }

    function updateLastHarvest(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId
    ) internal {
        s.stakeLog[collection][owner][tokenId].lastHarvestBlock = block.number;
    }

    // Capacity helpers (nice for UIs)
    function remainingGlobal(Storage storage s) internal view returns (uint256) {
        return GLOBAL_CAP - s.totalStakedAll;
    }

    function remainingTerm(Storage storage s) internal view returns (uint256) {
        return TERM_CAP - s.totalStakedTerm;
    }

    function remainingPermanent(Storage storage s) internal view returns (uint256) {
        return PERM_CAP - s.totalStakedPermanent;
    }

    // Optional compact snapshot for UIs
    function stakingStats(Storage storage s)
        internal
        view
        returns (
            uint256 totalAll,
            uint256 totalTerm,
            uint256 totalPerm,
            uint256 remAll,
            uint256 remTerm,
            uint256 remPerm,
            uint256 blueChipAll
        )
    {
        totalAll   = s.totalStakedAll;
        totalTerm  = s.totalStakedTerm;
        totalPerm  = s.totalStakedPermanent;
        remAll     = GLOBAL_CAP - totalAll;
        remTerm    = TERM_CAP   - totalTerm;
        remPerm    = PERM_CAP   - totalPerm;
        blueChipAll= s.totalBlueChipRegistered;
    }

    // ----------------------------- //
    //        MISC (UTILITY)         //
    // ----------------------------- //
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) z = 1;
    }
}
