// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Lightweight staking library (bookkeeping only).
library StakingLib {
    struct StakeInfo {
        uint256 stakeBlock;
        uint256 lastHarvestBlock;
        bool currentlyStaked;
        bool isPermanent;
        uint256 unstakeDeadlineBlock;
    }

    struct CollectionConfig {
        uint256 totalStaked;
        uint256 totalStakers;
        bool registered;
        uint256 declaredSupply;
    }

    struct Storage {
        // Staking caps and counters
        uint256 public constant GLOBAL_CAP = 1_000_000_000;
        uint256 public constant TERM_CAP   = 750_000_000;
        uint256 public constant PERM_CAP   = 250_000_000;
        
        uint256 public totalStakedAll;
        uint256 public totalStakedTerm;
        uint256 public totalStakedPermanent;

        mapping(address => CollectionConfig) collectionConfigs;
        mapping(address => mapping(address => mapping(uint256 => StakeInfo))) stakeLog;
        mapping(address => mapping(address => uint256[])) stakePortfolioByUser;
        mapping(address => mapping(uint256 => uint256)) indexOfTokenIdInStakePortfolio;
        uint256 totalStakedNFTsCount;
        uint256 baseRewardRate;
    }

    event InternalStakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event InternalUnstakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId);

    function initCollection(Storage storage s, address collection, uint256 declaredSupply) internal {
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        cfg.declaredSupply = declaredSupply;
        cfg.registered = true;
        cfg.totalStaked = 0;
        cfg.totalStakers = 0;
    }

    function recordTermStake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 currentBlock,
        uint256 termDurationBlocks,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        // Cap checks for term staking
        require(s.totalStakedAll + 1 <= s.GLOBAL_CAP, "CATA: global cap reached");
        require(s.totalStakedTerm + 1 <= s.TERM_CAP, "CATA: term cap reached");

        CollectionConfig storage cfg = s.collectionConfigs[collection];
        require(cfg.registered, "StakingLib: not reg");

        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        require(!info.currentlyStaked, "StakingLib: already staked");

        info.stakeBlock = currentBlock;
        info.lastHarvestBlock = currentBlock;
        info.currentlyStaked = true;
        info.isPermanent = false;
        info.unstakeDeadlineBlock = currentBlock + termDurationBlocks;

        if (s.stakePortfolioByUser[collection][staker].length == 0) cfg.totalStakers += 1;
        cfg.totalStaked += 1;

        s.totalStakedNFTsCount += 1;
        s.baseRewardRate += rewardRateIncrementPerNFT;

        s.stakePortfolioByUser[collection][staker].push(tokenId);
        s.indexOfTokenIdInStakePortfolio[collection][tokenId] = s.stakePortfolioByUser[collection][staker].length - 1;

        // Increment global counters
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
        // Cap checks for permanent staking
        require(s.totalStakedAll + 1 <= s.GLOBAL_CAP, "CATA: global cap reached");
        require(s.totalStakedPermanent + 1 <= s.PERM_CAP, "CATA: perm cap reached");

        CollectionConfig storage cfg = s.collectionConfigs[collection];
        require(cfg.registered, "StakingLib: not reg");

        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        require(!info.currentlyStaked, "StakingLib: already staked");

        info.stakeBlock = currentBlock;
        info.lastHarvestBlock = currentBlock;
        info.currentlyStaked = true;
        info.isPermanent = true;
        info.unstakeDeadlineBlock = 0;

        if (s.stakePortfolioByUser[collection][staker].length == 0) cfg.totalStakers += 1;
        cfg.totalStaked += 1;

        s.totalStakedNFTsCount += 1;
        s.baseRewardRate += rewardRateIncrementPerNFT;

        s.stakePortfolioByUser[collection][staker].push(tokenId);
        s.indexOfTokenIdInStakePortfolio[collection][tokenId] = s.stakePortfolioByUser[collection][staker].length - 1;

        // Increment global counters
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
        require(info.currentlyStaked, "StakingLib: not staked");

        info.currentlyStaked = false;

        uint256[] storage port = s.stakePortfolioByUser[collection][staker];
        uint256 idx = s.indexOfTokenIdInStakePortfolio[collection][tokenId];
        uint256 last = port.length - 1;
        if (idx != last) {
            uint256 lastTokenId = port[last];
            port[idx] = lastTokenId;
            s.indexOfTokenIdInStakePortfolio[collection][lastTokenId] = idx;
        }
        port.pop();
        delete s.indexOfTokenIdInStakePortfolio[collection][tokenId];

        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (port.length == 0 && cfg.totalStakers > 0) cfg.totalStakers -= 1;
        if (cfg.totalStaked > 0) cfg.totalStaked -= 1;

        if (s.baseRewardRate >= rewardRateIncrementPerNFT) s.baseRewardRate -= rewardRateIncrementPerNFT;
        if (s.totalStakedNFTsCount > 0) s.totalStakedNFTsCount -= 1;

        // Decrement global counters based on stake type
        s.totalStakedAll -= 1;
        if (info.isPermanent) {
            s.totalStakedPermanent -= 1;
        } else {
            s.totalStakedTerm -= 1;
        }

        emit InternalUnstakeRecorded(staker, collection, tokenId);
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
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) return 0;

        uint256 blocksPassed = block.number - info.lastHarvestBlock;
        uint256 numerator = blocksPassed * s.baseRewardRate;
        uint256 rewardAmount = (numerator / numberOfBlocksPerRewardUnit) / s.totalStakedNFTsCount;
        return rewardAmount;
    }

    function updateLastHarvest(Storage storage s, address collection, address owner, uint256 tokenId) internal {
        StakeInfo storage info = s.stakeLog[collection][owner][tokenId];
        info.lastHarvestBlock = block.number;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) z = 1;
    }
}
