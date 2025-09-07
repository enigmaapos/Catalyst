// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IERC721.sol";

library StakingLib {
    // ---- Errors
    error CollectionNotRegistered();
    error AlreadyStaked();
    error NotStaked();
    error CapReached();
    error NotOwner();
    error IndexOutOfBounds();

    // ---- Tiers
    enum CollectionTier { UNVERIFIED, VERIFIED }

    // ---- Storage layout
    struct StakeInfo {
        uint256 stakeBlock;
        uint256 lastHarvestBlock;
        bool    currentlyStaked;      // true for classic custody staking AND blue-chip virtual
        bool    isPermanent;
        uint256 unstakeDeadlineBlock; // term only
    }

    struct CollectionConfig {
        bool registered;
        CollectionTier tier;
        uint256 declaredSupply;
        uint256 totalStaked;          // (classic + virtual)
        uint256 totalStakers;         // unique wallets in this collection
        bool    allowVirtual;         // enabled for VERIFIED only
        address nft;                  // ERC721 collection address
    }

    struct Storage {
        // global counters
        uint256 totalStakedAll;
        uint256 totalStakedTerm;
        uint256 totalStakedPermanent;

        // collection -> config
        mapping(address => CollectionConfig) cfg;

        // collection -> owner -> tokenId -> stake info
        mapping(address => mapping(address => mapping(uint256 => StakeInfo))) stakeLog;

        // collection -> owner -> array of tokenIds (for enumeration)
        mapping(address => mapping(address => uint256[])) portfolio;
        // collection -> tokenId -> index in owner's portfolio
        mapping(address => mapping(uint256 => uint256)) indexInPortfolio;

        // reward math
        uint256 totalActive;      // # NFTs participating (classic + virtual)
        uint256 baseRewardRate;   // pulled from ConfigRegistry
    }

    // ---- Events
    event StakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId, bool permanent, bool virtualStake);
    event UnstakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId, bool virtualStake);

    // ---- Views
    function pendingRewards(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId,
        uint256 blocksPerUnit
    ) internal view returns (uint256) {
        StakeInfo memory info = s.stakeLog[collection][owner][tokenId];
        if (!info.currentlyStaked || s.baseRewardRate == 0 || s.totalActive == 0) return 0;
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) return 0;

        uint256 blocksPassed = block.number - info.lastHarvestBlock;
        uint256 numerator = blocksPassed * s.baseRewardRate;
        return (numerator / blocksPerUnit) / s.totalActive;
    }

    // ---- Mutators (classic staking)
    function stakeClassic(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 currentBlock,
        uint256 termDurationBlocks,
        bool permanent,
        Caps memory caps
    ) internal {
        CollectionConfig storage c = s.cfg[collection];
        if (!c.registered) revert CollectionNotRegistered();

        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        if (info.currentlyStaked) revert AlreadyStaked();

        // caps
        _enforceGlobalCaps(s, permanent, caps);

        info.stakeBlock        = currentBlock;
        info.lastHarvestBlock  = currentBlock;
        info.currentlyStaked   = true;
        info.isPermanent       = permanent;
        info.unstakeDeadlineBlock = permanent ? 0 : currentBlock + termDurationBlocks;

        // classic custody assumed already done by caller contract

        _afterStakeAccounting(s, c, staker, tokenId, permanent, false);
    }

    // ---- Mutators (blue-chip virtual staking)
    function registerVirtual(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId,
        bool permanent,
        uint256 currentBlock,
        IERC721 nft,
        Caps memory caps
    ) internal {
        CollectionConfig storage c = s.cfg[collection];
        if (!c.registered) revert CollectionNotRegistered();
        if (c.tier != CollectionTier.VERIFIED || !c.allowVirtual) revert CollectionNotRegistered();

        if (nft.ownerOf(tokenId) != owner) revert NotOwner();

        StakeInfo storage info = s.stakeLog[collection][owner][tokenId];
        if (info.currentlyStaked) revert AlreadyStaked();

        _enforceGlobalCaps(s, permanent, caps);

        info.stakeBlock        = currentBlock;
        info.lastHarvestBlock  = currentBlock;
        info.currentlyStaked   = true;
        info.isPermanent       = permanent;
        info.unstakeDeadlineBlock = permanent ? 0 : currentBlock + caps.termDurationBlocks;

        _afterStakeAccounting(s, c, owner, tokenId, permanent, true);
    }

    function unregisterVirtual(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId
    ) internal {
        StakeInfo storage info = s.stakeLog[collection][owner][tokenId];
        if (!info.currentlyStaked) revert NotStaked();

        bool wasPermanent = info.isPermanent;
        info.currentlyStaked = false;

        _afterUnstakeAccounting(s, s.cfg[collection], owner, tokenId, wasPermanent, true);
    }

    function unstakeClassic(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId
    ) internal {
        StakeInfo storage info = s.stakeLog[collection][owner][tokenId];
        if (!info.currentlyStaked) revert NotStaked();

        bool wasPermanent = info.isPermanent;
        info.currentlyStaked = false;

        _afterUnstakeAccounting(s, s.cfg[collection], owner, tokenId, wasPermanent, false);
    }

    // ---- Accounting helpers
    struct Caps {
        uint256 globalCap;
        uint256 termCap;
        uint256 permCap;
        uint256 perCollectionCap;
        uint256 termDurationBlocks;
    }

    function _enforceGlobalCaps(
        Storage storage s,
        bool permanent,
        Caps memory caps
    ) private {
        if (s.totalStakedAll + 1 > caps.globalCap) revert CapReached();
        if (permanent) {
            if (s.totalStakedPermanent + 1 > caps.permCap) revert CapReached();
        } else {
            if (s.totalStakedTerm + 1 > caps.termCap) revert CapReached();
        }
    }

    function _afterStakeAccounting(
        Storage storage s,
        CollectionConfig storage c,
        address owner,
        uint256 tokenId,
        bool permanent,
        bool isVirtual
    ) private {
        // per-collection cap
        if (c.totalStaked + 1 > c.declaredSupply || c.totalStaked + 1 > 20_000) revert CapReached();

        if (s.portfolio[c.nft][owner].length == 0) c.totalStakers += 1;
        c.totalStaked += 1;

        s.totalActive += 1;
        s.totalStakedAll += 1;
        if (permanent) s.totalStakedPermanent += 1; else s.totalStakedTerm += 1;

        s.portfolio[c.nft][owner].push(tokenId);
        s.indexInPortfolio[c.nft][tokenId] = s.portfolio[c.nft][owner].length - 1;

        emit StakeRecorded(owner, address(c.nft), tokenId, permanent, isVirtual);
    }

    function _afterUnstakeAccounting(
        Storage storage s,
        CollectionConfig storage c,
        address owner,
        uint256 tokenId,
        bool wasPermanent,
        bool wasVirtual
    ) private {
        uint256[] storage port = s.portfolio[c.nft][owner];
        if (port.length == 0) revert IndexOutOfBounds();
        uint256 idx = s.indexInPortfolio[c.nft][tokenId];
        uint256 last = port.length - 1;
        if (idx != last) {
            uint256 lastTokenId = port[last];
            port[idx] = lastTokenId;
            s.indexInPortfolio[c.nft][lastTokenId] = idx;
        }
        port.pop();
        delete s.indexInPortfolio[c.nft][tokenId];

        if (port.length == 0 && c.totalStakers > 0) c.totalStakers -= 1;
        if (c.totalStaked > 0) c.totalStaked -= 1;

        if (s.totalActive > 0) s.totalActive -= 1;
        if (s.totalStakedAll > 0) s.totalStakedAll -= 1;
        if (wasPermanent && s.totalStakedPermanent > 0) s.totalStakedPermanent -= 1;
        if (!wasPermanent && s.totalStakedTerm > 0) s.totalStakedTerm -= 1;

        emit UnstakeRecorded(owner, address(c.nft), tokenId, wasVirtual);
    }
}
