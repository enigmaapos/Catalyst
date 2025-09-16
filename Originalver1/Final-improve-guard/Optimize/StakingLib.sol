// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// --- Minimal interface to detect ownership without importing OZ Ownable ---
    interface IOwnable { function owner() external view returns (address); }

/// @notice Lightweight staking library (bookkeeping only) — optimized (packed structs, custom errors).
library StakingLib {
    // Staking caps declared at the library level (keep as uint256 constants for clarity)
    uint256 public constant GLOBAL_CAP = 1_000_000_000;
    uint256 public constant TERM_CAP = 750_000_000;
    uint256 public constant PERM_CAP = 250_000_000;

    // --- Custom errors (short) ---
    error SL_ZeroAddress();
    error SL_AlreadyRegistered();
    error SL_InvalidSupply();
    error SL_NotRegistered();
    error SL_AlreadyStaked();
    error SL_NotStaked();
    error SL_CapReached();
    error SL_BadParam();

    // --- Compact StakeInfo packed into a single slot where possible ---
    // Layout intention:
    // - stakeBlock, lastHarvestBlock, unstakeDeadlineBlock as uint32 (block.number fits)
    // - flags: uint8 bitfield: bit0 = currentlyStaked, bit1 = isPermanent
    struct StakeInfo {
        uint32 stakeBlock;           // 4 bytes
        uint32 lastHarvestBlock;     // 4 bytes
        uint32 unstakeDeadlineBlock; // 4 bytes; 0 if permanent
        uint8 flags;                 // 1 byte: bit0 currentlyStaked, bit1 isPermanent
        // packed into one 32-byte slot + remainder unused
 bool currentlyStaked;
   bool isPermanent;              // tracks if permanent stake
    }

    enum Tier {
        NONE,
        UNVERIFIED,
        VERIFIED,
        BLUECHIP
    }

    // Packed small counters for collection config
    struct CollectionConfig {
        uint32 totalStaked;     // number of tokens staked in this collection
        uint32 totalStakers;    // number of distinct stakers
        bool registered;        // 1 byte
        uint32 declaredSupply;  // declared max supply (fits into uint32)
        Tier tier;              // enum fits in uint8
        // (mappings reserved elsewhere)
    }

    // --- Storage struct (REORDERED & PACKED) ---
    // NOTE: Changing Storage layout breaks existing deployments. See migration notes below.
    struct Storage {
        // High-frequency counters (packed)
        uint32 totalStakedAll;
        uint32 totalStakedTerm;
        uint32 totalStakedPermanent;
        uint32 totalStakedNFTsCount;

        uint64 baseRewardRate; // might need larger depending on reward increments; choose 64 to be safe
        uint256 maxSupply;     // keep as uint256 if external config could be large
        address admin;

        // mappings (each occupies its own slot area)
        mapping(address => uint256) collectionTotalStaked;
        mapping(address => CollectionConfig) collectionConfigs;
        mapping(address => mapping(address => mapping(uint256 => StakeInfo))) stakeLog;
        mapping(address => mapping(address => uint256[])) stakePortfolioByUser;
        mapping(address => mapping(uint256 => uint256)) indexOfTokenIdInStakePortfolio;
    }

    // --- Events (short names kept) ---
    event InternalStakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event InternalUnstakeRecorded(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event CollectionRegistered(address indexed collection, address indexed registerer, Tier tier, uint256 declaredSupply);

    // -------------------------
    // Initialization / helpers
    // -------------------------

    function initCollection(Storage storage s, address collection, uint256 declaredSupply) internal {
        if (collection == address(0)) revert SL_ZeroAddress();
        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (cfg.registered) revert SL_AlreadyRegistered();
        // declaredSupply must fit uint32 and <= s.maxSupply
        if (declaredSupply == 0 || declaredSupply > s.maxSupply || declaredSupply > type(uint32).max) revert SL_InvalidSupply();

        cfg.registered = true;
        cfg.declaredSupply = uint32(declaredSupply);
        cfg.totalStaked = 0;
        cfg.totalStakers = 0;

        // Determine tier: if the collection's owner equals msg.sender OR s.admin => VERIFIED
        bool isVerified = false;
        // use minimal IOwnable; if collection doesn't implement owner(), the try/catch will handle it
        try IOwnable(collection).owner() returns (address owner) {
            if (owner == msg.sender) isVerified = true;
        } catch {
            // ignore
        }

        if (msg.sender == s.admin || isVerified) {
            cfg.tier = Tier.VERIFIED;
        } else {
            cfg.tier = Tier.UNVERIFIED;
        }

        emit CollectionRegistered(collection, msg.sender, cfg.tier, declaredSupply);
    }

    // -------------------------
    // Internal stake recorder (merged)
    // -------------------------
    function _recordStake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint32 currentBlock,
        bool isPermanent,
        uint32 termDurationBlocks,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        if (staker == address(0)) revert SL_ZeroAddress();

        // global caps (use uint256 arithmetic for caps)
        if (uint256(s.totalStakedAll) + 1 > GLOBAL_CAP) revert SL_CapReached();
        if (!isPermanent) {
            if (uint256(s.totalStakedTerm) + 1 > TERM_CAP) revert SL_CapReached();
        } else {
            if (uint256(s.totalStakedPermanent) + 1 > PERM_CAP) revert SL_CapReached();
        }

        CollectionConfig storage cfg = s.collectionConfigs[collection];
        if (!cfg.registered) revert SL_NotRegistered();

        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        if ((info.flags & 1) != 0) revert SL_AlreadyStaked(); // currentlyStaked bit

        // set stake info (cast block numbers to uint32)
        info.stakeBlock = currentBlock;
        info.lastHarvestBlock = currentBlock;
        info.unstakeDeadlineBlock = isPermanent ? uint32(0) : uint32(currentBlock + termDurationBlocks);
        // set flags: bit0 currentlyStaked, bit1 isPermanent
        uint8 f = 1 | (isPermanent ? 2 : 0);
        info.flags = f;

        // portfolio bookkeeping
        if (s.stakePortfolioByUser[collection][staker].length == 0) {
            unchecked { cfg.totalStakers += 1; }
        }
        unchecked { cfg.totalStaked += 1; }

        s.totalStakedNFTsCount += 1;
        // baseRewardRate is uint64; be careful with overflow — expect rewardRateIncrementPerNFT to be small
        s.baseRewardRate += uint64(rewardRateIncrementPerNFT);

        s.stakePortfolioByUser[collection][staker].push(tokenId);
        s.indexOfTokenIdInStakePortfolio[collection][tokenId] = s.stakePortfolioByUser[collection][staker].length - 1;

        // global counters (packed)
        unchecked { s.totalStakedAll += 1; }
        if (isPermanent) { unchecked { s.totalStakedPermanent += 1; } }
        else { unchecked { s.totalStakedTerm += 1; } }

        emit InternalStakeRecorded(staker, collection, tokenId);
    }

    // Public-style wrappers to maintain original API names (callers won't need to change)
    function recordTermStake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 currentBlock_,
        uint256 termDurationBlocks_,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        _recordStake(
            s,
            collection,
            staker,
            tokenId,
            uint32(currentBlock_),
            false,
            uint32(termDurationBlocks_),
            rewardRateIncrementPerNFT
        );
    }

    function recordPermanentStake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 currentBlock_,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        _recordStake(
            s,
            collection,
            staker,
            tokenId,
            uint32(currentBlock_),
            true,
            0,
            rewardRateIncrementPerNFT
        );
    }

    // -------------------------
    // Unstake (uses packed fields)
    // -------------------------
    function recordUnstake(
        Storage storage s,
        address collection,
        address staker,
        uint256 tokenId,
        uint256 rewardRateIncrementPerNFT
    ) internal {
        StakeInfo storage info = s.stakeLog[collection][staker][tokenId];
        if ((info.flags & 1) == 0) revert SL_NotStaked();

        bool wasPermanent = (info.flags & 2) != 0;

        // mark not staked
        info.flags = 0;

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
        if (port.length == 0 && cfg.totalStakers > 0) { unchecked { cfg.totalStakers -= 1; } }
        if (cfg.totalStaked > 0) { unchecked { cfg.totalStaked -= 1; } }

        // decrement reward rate and counters carefully
        if (s.baseRewardRate >= uint64(rewardRateIncrementPerNFT)) {
            unchecked { s.baseRewardRate -= uint64(rewardRateIncrementPerNFT); }
        }
        if (s.totalStakedNFTsCount > 0) { unchecked { s.totalStakedNFTsCount -= 1; } }

        // global counters
        unchecked { s.totalStakedAll -= 1; }
        if (wasPermanent) {
            if (s.totalStakedPermanent > 0) { unchecked { s.totalStakedPermanent -= 1; } }
        } else {
            if (s.totalStakedTerm > 0) { unchecked { s.totalStakedTerm -= 1; } }
        }

        emit InternalUnstakeRecorded(staker, collection, tokenId);
    }

    // -------------------------
    // Rewards view & helpers
    // -------------------------
    function pendingRewards(
        Storage storage s,
        address collection,
        address owner,
        uint256 tokenId,
        uint256 numberOfBlocksPerRewardUnit
    ) internal view returns (uint256) {
        StakeInfo memory info = s.stakeLog[collection][owner][tokenId];
        if ((info.flags & 1) == 0) return 0; // not staked
        if (s.baseRewardRate == 0 || s.totalStakedNFTsCount == 0) return 0;
        // if term stake expired, no reward
        if (((info.flags & 2) == 0) && uint32(block.number) >= info.unstakeDeadlineBlock) return 0;

        uint256 blocksPassed = uint256(uint32(block.number) - info.lastHarvestBlock);
        if (blocksPassed == 0) return 0;

        // numerator = blocksPassed * baseRewardRate
        uint256 numerator = blocksPassed * uint256(s.baseRewardRate);
        // divide by numberOfBlocksPerRewardUnit first then by total staked
        uint256 rewardAmount = (numerator / numberOfBlocksPerRewardUnit) / s.totalStakedNFTsCount;
        return rewardAmount;
    }

    function updateLastHarvest(Storage storage s, address collection, address owner, uint256 tokenId) internal {
        StakeInfo storage info = s.stakeLog[collection][owner][tokenId];
        info.lastHarvestBlock = uint32(block.number);
    }

    // Small pure helper (kept; optional to remove)
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) z = 1;
    }
}
