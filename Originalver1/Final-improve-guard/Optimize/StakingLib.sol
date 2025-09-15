// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Lightweight staking library (bookkeeping only).
library StakingLib {
    struct StakeInfo {
        uint256 stakeBlock;
        uint256 lastHarvestBlock;
        uint256 unstakeDeadlineBlock;
        bool currentlyStaked;
        bool isPermanent;
    }

    enum Tier {
        NONE,
        UNVERIFIED,
        VERIFIED,
        BLUECHIP
    }

    struct CollectionConfig {
        uint256 totalStaked;
        uint256 totalStakers;
        bool registered;
        uint256 declaredSupply;
        Tier tier;
    }

    struct Storage {
        // Counters for staked NFTs
        uint256 totalStakedAll;
        uint256 totalStakedTerm;
        uint256 totalStakedPermanent;

        mapping(address => uint256) collectionTotalStaked;
        mapping(address => CollectionConfig) collectionConfigs;
        mapping(address => mapping(address => mapping(uint256 => StakeInfo))) stakeLog;
        mapping(address => mapping(address => uint256[])) stakePortfolioByUser;
        mapping(address => mapping(uint256 => uint256)) indexOfTokenIdInStakePortfolio;
        uint256 totalStakedNFTsCount;
        uint256 baseRewardRate;
        uint256 maxSupply;
        address admin;
    }

    event InternalStakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event InternalUnstakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event CollectionRegistered(address indexed collection, address indexed registerer, Tier tier, uint256 declaredSupply);

    function initCollection(Storage storage s, address collection, uint256 declaredSupply) internal {
        if (collection == address(0)) { revert ZeroAddress(); }
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (cfg.registered) { revert AlreadyExists(); }
        if (declaredSupply == 0 || declaredSupply > s.maxSupply) { revert BadParam(); }

        cfg.registered = true;
        cfg.declaredSupply = declaredSupply;
        cfg.totalStaked = 0;
        cfg.totalStakers = 0;

        // Determine tier based on caller identity
        bool isVerified = false;
        try Ownable(collection).owner() returns (address owner) {
            if (owner == msg.sender) {
                isVerified = true;
            }
        } catch {
            // If collection is not Ownable, leave isVerified = false
        }

        if (msg.sender == s.admin || isVerified) {
            cfg.tier = Tier.VERIFIED;
        } else {
            cfg.tier = Tier.UNVERIFIED;
        }

        emit CollectionRegistered(collection, msg.sender, cfg.tier, declaredSupply);
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
        if (staker == address(0)) { revert ZeroAddress(); }
        if (s.totalStakedAll + 1 > type(uint256).max || s.totalStakedTerm + 1 > type(uint256).max) { revert StakingCapReached(); }
        
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (!cfg.registered) { revert NotRegistered(); }
        
        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        if (info.currentlyStaked) { revert AlreadyStaked(); }

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
        if (staker == address(0)) { revert ZeroAddress(); }
        if (s.totalStakedAll + 1 > type(uint256).max || s.totalStakedPermanent + 1 > type(uint256).max) { revert StakingCapReached(); }

        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (!cfg.registered) { revert NotRegistered(); }

        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        if (info.currentlyStaked) { revert AlreadyStaked(); }

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
        if (!info.currentlyStaked) { revert NotStaked(); }

        bool wasPermanent = info.isPermanent;
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

        s.totalStakedAll -= 1;
        if (wasPermanent) {
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
        if (blocksPassed == 0) return 0;
        uint256 numerator = blocksPassed * s.baseRewardRate;
        uint256 rewardAmount = (numerator / numberOfBlocksPerRewardUnit) / s.totalStakedNFTsCount;
        return rewardAmount;
    }

    function updateLastHarvest(Storage storage s, address collection, address owner, uint256 tokenId) internal {
        StakeInfo storage info = s.stakeLog[collection][owner][tokenId];
        info.lastHarvestBlock = block.number;
    }
}
