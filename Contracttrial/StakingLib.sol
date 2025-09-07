// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title StakingLib
 * @notice Bookkeeping for both custodial staking (unverified) and
 *         non-custodial blue-chip registration (verified).
 *         Caps: 1B global units; 75% term / 25% permanent; 20,000 per collection.
 */
library StakingLib {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint256 public constant GLOBAL_CAP = 1_000_000_000;
    uint256 public constant TERM_CAP   = 750_000_000;
    uint256 public constant PERM_CAP   = 250_000_000;
    uint256 public constant PER_COLLECTION_CAP = 20_000;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error NotRegisteredCollection();
    error AlreadyCounted();
    error NotCounted();
    error GlobalCapReached();
    error TermCapReached();
    error PermCapReached();
    error CollectionCapReached();
    error TermExpired();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/
    enum Mode { Custody, BlueChip } // Custody = NFT held by contract; BlueChip = owner holds NFT

    struct StakeInfo {
        uint256 stakeBlock;
        uint256 lastHarvestBlock;
        bool active;
        bool permanent;
        uint256 termDeadlineBlock; // 0 for permanent
        Mode mode;
    }

    struct CollectionConfig {
        bool registered;
        bool verified;               // true => blue-chip path allowed
        uint256 declaredSupply;
        uint256 totalUnits;          // active units for this collection
        uint256 totalStakers;
    }

    struct Storage {
        // global counters
        uint256 totalAll;
        uint256 totalTerm;
        uint256 totalPerm;

        // reward accounting
        uint256 totalActiveUnits;    // denominator for rate-sharing
        uint256 baseRewardRate;      // abstract units per block

        // mappings
        mapping(address => CollectionConfig) collections;
        // collection => owner => tokenId => info
        mapping(address => mapping(address => mapping(uint256 => StakeInfo))) info;
        // portfolio
        mapping(address => mapping(address => uint256[])) portfolio;
        mapping(address => mapping(uint256 => uint256)) indexOf; // collection => tokenId => idx
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL: COLLECTION
    //////////////////////////////////////////////////////////////*/
    function initCollection(
        Storage storage s,
        address collection,
        uint256 declaredSupply,
        bool verified
    ) internal {
        CollectionConfig storage c = s.collections[collection];
        c.registered = true;
        c.verified = verified;
        c.declaredSupply = declaredSupply;
        c.totalUnits = 0;
        c.totalStakers = 0;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL: ADD / REMOVE UNIT
    //////////////////////////////////////////////////////////////*/
    function _checkCapsAdd(
        Storage storage s,
        address collection,
        bool permanent
    ) private view {
        if (!s.collections[collection].registered) revert NotRegisteredCollection();
        if (s.totalAll + 1 > GLOBAL_CAP) revert GlobalCapReached();
        if (permanent) {
            if (s.totalPerm + 1 > PERM_CAP) revert PermCapReached();
        } else {
            if (s.totalTerm + 1 > TERM_CAP) revert TermCapReached();
        }
        if (s.collections[collection].totalUnits + 1 > PER_COLLECTION_CAP) revert CollectionCapReached();
    }

    function addUnit(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId,
        bool permanent,
        Mode mode,
        uint256 currentBlock,
        uint256 termDuration,
        uint256 rewardRateIncrement
    ) internal {
        _checkCapsAdd(s, collection, permanent);

        StakeInfo storage st = s.info[collection][owner][tokenId];
        if (st.active) revert AlreadyCounted();

        st.stakeBlock = currentBlock;
        st.lastHarvestBlock = currentBlock;
        st.active = true;
        st.permanent = permanent;
        st.mode = mode;
        st.termDeadlineBlock = permanent ? 0 : (currentBlock + termDuration);

        if (s.portfolio[collection][owner].length == 0) {
            s.collections[collection].totalStakers += 1;
        }
        s.collections[collection].totalUnits += 1;

        s.totalAll += 1;
        if (permanent) s.totalPerm += 1; else s.totalTerm += 1;

        s.totalActiveUnits += 1;
        s.baseRewardRate += rewardRateIncrement;

        // push
        s.portfolio[collection][owner].push(tokenId);
        s.indexOf[collection][tokenId] = s.portfolio[collection][owner].length - 1;
    }

    function removeUnit(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId,
        uint256 rewardRateDecrement
    ) internal {
        StakeInfo storage st = s.info[collection][owner][tokenId];
        if (!st.active) revert NotCounted();

        st.active = false;

        // portfolio swap-remove
        uint256[] storage port = s.portfolio[collection][owner];
        uint256 idx = s.indexOf[collection][tokenId];
        uint256 last = port.length - 1;
        if (idx != last) {
            uint256 lastId = port[last];
            port[idx] = lastId;
            s.indexOf[collection][lastId] = idx;
        }
        port.pop();
        delete s.indexOf[collection][tokenId];

        // totals
        if (s.collections[collection].totalUnits > 0) s.collections[collection].totalUnits -= 1;
        if (port.length == 0 && s.collections[collection].totalStakers > 0) {
            s.collections[collection].totalStakers -= 1;
        }

        s.totalAll -= 1;
        if (st.permanent) s.totalPerm -= 1; else s.totalTerm -= 1;

        if (s.totalActiveUnits > 0) s.totalActiveUnits -= 1;
        if (s.baseRewardRate >= rewardRateDecrement) s.baseRewardRate -= rewardRateDecrement;
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL: REWARDS
    //////////////////////////////////////////////////////////////*/
    function pendingRewards(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId,
        uint256 blocksPerUnit
    ) internal view returns (uint256) {
        StakeInfo memory st = s.info[collection][owner][tokenId];
        if (!st.active || s.baseRewardRate == 0 || s.totalActiveUnits == 0) return 0;
        if (!st.permanent && block.number >= st.termDeadlineBlock) return 0;

        uint256 blocksPassed = block.number - st.lastHarvestBlock;
        uint256 num = blocksPassed * s.baseRewardRate;
        return (num / blocksPerUnit) / s.totalActiveUnits;
    }

    function updateHarvestBlock(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId
    ) internal {
        s.info[collection][owner][tokenId].lastHarvestBlock = block.number;
    }
}
