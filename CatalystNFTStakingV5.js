// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  CatalystNFTStaking - 
  - ERC20 (CATA) + NFT staking + internal treasury vault + governance + Top-100 leaderboard + quarterly bonus (top 10%)
  - Use with care: test & audit before mainnet
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract CatalystNFTStakingV5 is ERC20, AccessControl, IERC721Receiver, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Roles
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // Constants
    uint256 public constant DECIMALS_FACTOR = 10 ** 18;
    uint256 public constant TOP_TRACKED = 100; // top 100 burners tracked
    uint256 public constant DEPLOYER_FEE_SHARE_RATE = 50; // 50% of non-burn (i.e., 5% overall)
    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    // Structs
    struct CollectionConfig {
        uint256 totalStaked;
        uint256 totalStakers;
        bool registered;
    }

    struct StakeInfo {
        uint256 lastHarvestBlock;
        bool currentlyStaked;
        bool isPermanent;
        uint256 unstakeDeadlineBlock;
    }

    enum ProposalParam {
        NONE,
        SET_BASE_REWARD_RATE,
        SET_BONUS_CAP_PERCENT,
        SET_EMISSION_CAP,
        SET_MINTING_ENABLED,
        SET_QUARTERLY_BLOCKS,
        SET_COLLECTION_REGISTRATION_FEE,
        SET_UNSTAKE_BURN_FEE,
        SET_PROPOSAL_DURATION_BLOCKS,
        SET_QUORUM_VOTES,
        SET_MAX_VOTE_WEIGHT,
        LAST
    }

    struct Proposal {
        uint256 id;
        address proposer;
        ProposalParam param;
        uint256 value;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
    }

    // Collections
    EnumerableSet.AddressSet private _registeredCollections;
    mapping(address => CollectionConfig) public collectionConfigs;

    // Staking
    mapping(address => mapping(address => mapping(uint256 => StakeInfo))) public stakeLog; // collection => user => tokenId => info
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser; // collection => user => tokenIds
    mapping(address => mapping(uint256 => uint256)) public indexOfTokenIdInStakePortfolio; // collection => tokenId => index

    // Welcome bonus
    mapping(address => mapping(uint256 => bool)) public welcomeBonusCollected; // collection => tokenId => bool
    mapping(address => uint256) public lastStakingBlock; // per-user cooldown

    // Burns & treasury
    mapping(address => uint256) public burnedCatalystByCollection; // attributed to collection (protocol-origin)
    mapping(address => uint256) public burnedByUser; // user-attributed burns
    uint256 public totalBurnedCATA;
    uint256 public treasuryBalance; // tokens assigned to treasury (still held in contract)

    // Reward & fee params
    uint256 public numberOfBlocksPerRewardUnit;
    uint256 public collectionRegistrationFee;
    uint256 public unstakeBurnFee;
    uint256 public totalStakedNFTsCount;
    uint256 public baseRewardRate;
    uint256 public initialHarvestBurnFeeRate;
    uint256 public termDurationBlocks;
    uint256 public stakingCooldownBlocks;
    uint256 public harvestRateAdjustmentFactor;
    uint256 public initialCollectionFee;
    uint256 public feeMultiplier;
    uint256 public rewardRateIncrementPerNFT;
    uint256 public welcomeBonusBaseRate;
    uint256 public welcomeBonusIncrementPerNFT;

    address public immutable deployerAddress;

    // Emission controls
    bool public mintingEnabled;
    uint256 public emissionCap;
    uint256 public totalMintedByContract;

    // Quarterly bonus (top 10% of tracked)
    uint256 public quarterlyBlocks;
    uint256 public lastQuarterlyDistributionBlock;
    uint256 public bonusCapPercent; // e.g., 5 => 5% of treasuryBalance per quarter
    uint256 public minBurnForBonus; // optional min threshold for winners
    uint256 public minStakeForBonus; // optional min staked NFTs to be eligible

    // Governance
    uint256 public proposalDurationBlocks;
    uint256 public quorumVotes; // minimal forVotes total required
    uint256 public maxVoteWeight; // cap on vote weight per address
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVotedOnProposal;

    // Leaderboard (top 100)
    address[TOP_TRACKED] public topBurners;
    uint256[TOP_TRACKED] public topBurnedAmounts;
    uint256 public trackedCount;
    mapping(address => uint256) public burnerIndexPlusOne; // index+1, 0 = not tracked

    // Events
    event CollectionAdded(address indexed collection);
    event NFTStaked(address indexed owner, address indexed collection, uint256 tokenId, bool permanent);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 tokenId);
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payout, uint256 burned);
    event PermanentStakeFeePaid(address indexed staker, uint256 feeAmount);
    event BurnedByUser(address indexed user, uint256 amount, address indexed collection);
    event BonusDistributed(uint256 pool, uint256 winners, uint256 timestamp);
    event ProposalCreated(uint256 id, address proposer, ProposalParam param, uint256 value, uint256 startBlock, uint256 endBlock);
    event Voted(uint256 proposalId, address voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 id, ProposalParam param, uint256 value);

    // Modifiers
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: staking cooldown");
        _;
    }
    modifier onlyAdmin() {
        require(hasRole(CONTRACT_ADMIN_ROLE, _msgSender()), "CATA: not admin");
        _;
    }

    // Constructor
    constructor(
        address _owner,
        uint256 _initialCollectionFee,
        uint256 _feeMultiplier,
        uint256 _rewardRateIncrementPerNFT,
        uint256 _welcomeBonusBaseRate,
        uint256 _welcomeBonusIncrementPerNFT,
        uint256 _initialHarvestBurnFeeRate,
        uint256 _termDurationBlocks,
        uint256 _collectionRegistrationFee,
        uint256 _unstakeBurnFee,
        uint256 _stakingCooldownBlocks,
        uint256 _harvestRateAdjustmentFactor,
        uint256 _emissionCap,
        uint256 _quarterlyBlocks,
        uint256 _bonusCapPercent,
        uint256 _proposalDurationBlocks,
        uint256 _quorumVotes,
        uint256 _maxVoteWeight
    ) ERC20("Catalyst", "CATA") {
        require(_owner != address(0), "CATA: invalid owner");

        // initial supply minted to owner
        _mint(_owner, 25_185_000 * DECIMALS_FACTOR);

        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        _setupRole(CONTRACT_ADMIN_ROLE, _owner);

        deployerAddress = _owner;

        // defaults and params
        numberOfBlocksPerRewardUnit = 18782;
        initialCollectionFee = _initialCollectionFee;
        feeMultiplier = _feeMultiplier;
        rewardRateIncrementPerNFT = _rewardRateIncrementPerNFT;
        welcomeBonusBaseRate = _welcomeBonusBaseRate;
        welcomeBonusIncrementPerNFT = _welcomeBonusIncrementPerNFT;
        termDurationBlocks = _termDurationBlocks;
        collectionRegistrationFee = _collectionRegistrationFee;
        unstakeBurnFee = _unstakeBurnFee;
        stakingCooldownBlocks = _stakingCooldownBlocks;
        initialHarvestBurnFeeRate = _initialHarvestBurnFeeRate;
        harvestRateAdjustmentFactor = _harvestRateAdjustmentFactor;

        emissionCap = _emissionCap;
        mintingEnabled = true;

        quarterlyBlocks = _quarterlyBlocks;
        bonusCapPercent = _bonusCapPercent;

        proposalDurationBlocks = _proposalDurationBlocks;
        quorumVotes = _quorumVotes;
        maxVoteWeight = _maxVoteWeight;
    }

    // --- Math helper
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) z = 1;
    }

    // dynamic fees & rates
    function _getDynamicPermanentStakeFee() internal view returns (uint256) {
        return initialCollectionFee + (_sqrt(totalStakedNFTsCount) * feeMultiplier);
    }
    function _getDynamicHarvestBurnFeeRate() internal view returns (uint256) {
        if (harvestRateAdjustmentFactor == 0) return initialHarvestBurnFeeRate;
        uint256 rate = initialHarvestBurnFeeRate + (baseRewardRate / harvestRateAdjustmentFactor);
        return rate > 90 ? 90 : rate;
    }

    // mint with cap enforcement
    function _mintWithCap(address to, uint256 amount) internal {
        require(mintingEnabled, "CATA: minting disabled");
        if (emissionCap > 0) {
            require(totalMintedByContract + amount <= emissionCap, "CATA: emission cap reached");
        }
        totalMintedByContract += amount;
        _mint(to, amount);
    }

    // ---------------------------
    // Leaderboard (Top-100) maintenance
    // Called whenever burnedByUser[user] increases and we want to reflect in leaderboard
    // ---------------------------
    function _updateLeaderboard(address user) internal {
        uint256 amount = burnedByUser[user];
        if (amount == 0) return;

        uint256 idxPlusOne = burnerIndexPlusOne[user];

        if (idxPlusOne > 0) {
            // already tracked -> update and bubble up
            uint256 idx = idxPlusOne - 1;
            topBurnedAmounts[idx] = amount;
            while (idx > 0 && topBurnedAmounts[idx] > topBurnedAmounts[idx - 1]) {
                // swap amounts
                (topBurnedAmounts[idx], topBurnedAmounts[idx - 1]) = (topBurnedAmounts[idx - 1], topBurnedAmounts[idx]);
                // swap addresses
                (topBurners[idx], topBurners[idx - 1]) = (topBurners[idx - 1], topBurners[idx]);
                // update indices
                burnerIndexPlusOne[topBurners[idx]] = idx + 1;
                burnerIndexPlusOne[topBurners[idx - 1]] = idx;
                idx--;
            }
            return;
        } else {
            // not tracked
            if (trackedCount < TOP_TRACKED) {
                // append
                uint256 pos = trackedCount;
                topBurners[pos] = user;
                topBurnedAmounts[pos] = amount;
                burnerIndexPlusOne[user] = pos + 1;
                trackedCount++;
                // bubble up
                uint256 idx = pos;
                while (idx > 0 && topBurnedAmounts[idx] > topBurnedAmounts[idx - 1]) {
                    (topBurnedAmounts[idx], topBurnedAmounts[idx - 1]) = (topBurnedAmounts[idx - 1], topBurnedAmounts[idx]);
                    (topBurners[idx], topBurners[idx - 1]) = (topBurners[idx - 1], topBurners[idx]);
                    burnerIndexPlusOne[topBurners[idx]] = idx + 1;
                    burnerIndexPlusOne[topBurners[idx - 1]] = idx;
                    idx--;
                }
                return;
            } else {
                // full -> check if qualifies by beating last
                uint256 lastIndex = trackedCount - 1;
                if (amount <= topBurnedAmounts[lastIndex]) return; // doesn't qualify
                // remove last
                address removed = topBurners[lastIndex];
                burnerIndexPlusOne[removed] = 0;
                // put new at last and bubble up
                topBurners[lastIndex] = user;
                topBurnedAmounts[lastIndex] = amount;
                burnerIndexPlusOne[user] = lastIndex + 1;
                uint256 idx = lastIndex;
                while (idx > 0 && topBurnedAmounts[idx] > topBurnedAmounts[idx - 1]) {
                    (topBurnedAmounts[idx], topBurnedAmounts[idx - 1]) = (topBurnedAmounts[idx - 1], topBurnedAmounts[idx]);
                    (topBurners[idx], topBurners[idx - 1]) = (topBurners[idx - 1], topBurners[idx]);
                    burnerIndexPlusOne[topBurners[idx]] = idx + 1;
                    burnerIndexPlusOne[topBurners[idx - 1]] = idx;
                    idx--;
                }
                return;
            }
        }
    }

    // ---------------------------
    // Fee splitter 90/9/1 (fee must already be transferred into contract)
    // If payer != address(0) then burned portion is attributed to payer (user-attributed burn)
    // ---------------------------
    function _distributeFee(uint256 feeAmount, address collectionAddress, address payer) internal {
        require(feeAmount > 0, "CATA: zero fee");
        require(balanceOf(address(this)) >= feeAmount, "CATA: contract lacks fee");

        uint256 burnAmount = (feeAmount * 90) / 100;
        uint256 nonBurn = feeAmount - burnAmount; // 10%
        uint256 deployerShare = (nonBurn * DEPLOYER_FEE_SHARE_RATE) / 100; // 5% overall
        uint256 treasuryShare = nonBurn - deployerShare; // 5% overall

        // burn portion from contract
        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
            burnedCatalystByCollection[collectionAddress] += burnAmount;
            totalBurnedCATA += burnAmount;
            if (payer != address(0)) {
                burnedByUser[payer] += burnAmount;
                emit BurnedByUser(payer, burnAmount, collectionAddress);
                // update leaderboard
                _updateLeaderboard(payer);
            }
        }

        // deployer share
        if (deployerShare > 0) {
            _transfer(address(this), deployerAddress, deployerShare);
        }

        // treasury share remains in contract but increment internal accounting
        if (treasuryShare > 0) {
            treasuryBalance += treasuryShare;
        }
    }

    // ---------------------------
    // Collection registration (admin) - caller must have CATA and approved transfer to contract internally uses transfer
    // ---------------------------
    function setCollectionConfig(address collectionAddress) external onlyAdmin nonReentrant whenNotPaused {
        require(collectionAddress != address(0), "CATA: invalid collection");
        require(!collectionConfigs[collectionAddress].registered, "CATA: already registered");

        uint256 fee = collectionRegistrationFee;
        require(balanceOf(_msgSender()) >= fee, "CATA: insufficient CATA");

        // transfer fee into contract
        _transfer(_msgSender(), address(this), fee);

        // distribute & attribute to admin (payer)
        _distributeFee(fee, collectionAddress, _msgSender());

        collectionConfigs[collectionAddress] = CollectionConfig({ totalStaked: 0, totalStakers: 0, registered: true });
        _registeredCollections.add(collectionAddress);
        emit CollectionAdded(collectionAddress);
    }

    // ---------------------------
    // Staking: term stake
    // ---------------------------
    function termStake(address collectionAddress, uint256 tokenId) external nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: collection not registered");
        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        info.lastHarvestBlock = block.number;
        info.currentlyStaked = true;
        info.isPermanent = false;
        info.unstakeDeadlineBlock = block.number + termDurationBlocks;

        CollectionConfig storage cfg = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][_msgSender()].length == 0) cfg.totalStakers += 1;
        cfg.totalStaked += 1;
        totalStakedNFTsCount += 1;
        baseRewardRate += rewardRateIncrementPerNFT;

        stakePortfolioByUser[collectionAddress][_msgSender()].push(tokenId);
        indexOfTokenIdInStakePortfolio[collectionAddress][tokenId] = stakePortfolioByUser[collectionAddress][_msgSender()].length - 1;

        if (!welcomeBonusCollected[collectionAddress][tokenId]) {
            uint256 dynamicWelcomeBonus = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
            if (dynamicWelcomeBonus > 0) _mintWithCap(_msgSender(), dynamicWelcomeBonus);
            welcomeBonusCollected[collectionAddress][tokenId] = true;
        }

        lastStakingBlock[_msgSender()] = block.number;
        emit NFTStaked(_msgSender(), collectionAddress, tokenId, false);
    }

    // ---------------------------
    // Staking: permanent stake (requires dynamic fee)
    // ---------------------------
    function permanentStake(address collectionAddress, uint256 tokenId) external nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: collection not registered");
        uint256 currentFee = _getDynamicPermanentStakeFee();
        require(balanceOf(_msgSender()) >= currentFee, "CATA: insufficient CATA for fee");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        // collect fee into contract and distribute
        _transfer(_msgSender(), address(this), currentFee);
        _distributeFee(currentFee, collectionAddress, _msgSender());

        info.lastHarvestBlock = block.number;
        info.currentlyStaked = true;
        info.isPermanent = true;
        info.unstakeDeadlineBlock = 0;

        CollectionConfig storage cfg = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][_msgSender()].length == 0) cfg.totalStakers += 1;
        cfg.totalStaked += 1;
        totalStakedNFTsCount += 1;
        baseRewardRate += rewardRateIncrementPerNFT;

        stakePortfolioByUser[collectionAddress][_msgSender()].push(tokenId);
        indexOfTokenIdInStakePortfolio[collectionAddress][tokenId] = stakePortfolioByUser[collectionAddress][_msgSender()].length - 1;

        if (!welcomeBonusCollected[collectionAddress][tokenId]) {
            uint256 dynamicWelcomeBonus = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
            if (dynamicWelcomeBonus > 0) _mintWithCap(_msgSender(), dynamicWelcomeBonus);
            welcomeBonusCollected[collectionAddress][tokenId] = true;
        }

        lastStakingBlock[_msgSender()] = block.number;
        emit PermanentStakeFeePaid(_msgSender(), currentFee);
        emit NFTStaked(_msgSender(), collectionAddress, tokenId, true);
    }

    // ---------------------------
    // Unstake
    // ---------------------------
    function unstake(address collectionAddress, uint256 tokenId) external nonReentrant whenNotPaused {
        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(info.currentlyStaked, "CATA: not staked");
        if (!info.isPermanent) require(block.number >= info.unstakeDeadlineBlock, "CATA: term not expired");

        // harvest first
        _harvest(collectionAddress, _msgSender(), tokenId);

        // collect unstake burn fee
        require(balanceOf(_msgSender()) >= unstakeBurnFee, "CATA: insufficient for unstake fee");
        _transfer(_msgSender(), address(this), unstakeBurnFee);
        _distributeFee(unstakeBurnFee, collectionAddress, _msgSender());

        // mark unstaked and remove from portfolio
        info.currentlyStaked = false;
        uint256[] storage portfolio = stakePortfolioByUser[collectionAddress][_msgSender()];
        uint256 indexToRemove = indexOfTokenIdInStakePortfolio[collectionAddress][tokenId];
        uint256 lastIndex = portfolio.length - 1;
        if (indexToRemove != lastIndex) {
            uint256 lastTokenId = portfolio[lastIndex];
            portfolio[indexToRemove] = lastTokenId;
            indexOfTokenIdInStakePortfolio[collectionAddress][lastTokenId] = indexToRemove;
        }
        portfolio.pop();
        delete indexOfTokenIdInStakePortfolio[collectionAddress][tokenId];

        IERC721(collectionAddress).safeTransferFrom(address(this), _msgSender(), tokenId);

        CollectionConfig storage cfg = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][_msgSender()].length == 0) {
            if (cfg.totalStakers > 0) cfg.totalStakers -= 1;
        }
        if (cfg.totalStaked > 0) cfg.totalStaked -= 1;
        if (totalStakedNFTsCount > 0) totalStakedNFTsCount -= 1;
        if (baseRewardRate >= rewardRateIncrementPerNFT) baseRewardRate -= rewardRateIncrementPerNFT;

        emit NFTUnstaked(_msgSender(), collectionAddress, tokenId);
    }

    // ---------------------------
    // Harvest (internal) and batch harvest
    // ---------------------------
    function _harvest(address collectionAddress, address user, uint256 tokenId) internal {
        StakeInfo storage info = stakeLog[collectionAddress][user][tokenId];
        uint256 rewardAmount = pendingRewards(collectionAddress, user, tokenId);
        if (rewardAmount == 0) {
            info.lastHarvestBlock = block.number;
            return;
        }

        require(mintingEnabled, "CATA: minting disabled");

        // mint rewards into contract (so contract can burn portion and then pay out)
        _mintWithCap(address(this), rewardAmount);

        uint256 dynamicBurnRate = _getDynamicHarvestBurnFeeRate();
        uint256 burnAmount = (rewardAmount * dynamicBurnRate) / 100;
        uint256 payout = rewardAmount - burnAmount;

        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
            burnedCatalystByCollection[collectionAddress] += burnAmount;
            totalBurnedCATA += burnAmount;
            // Note: harvest burn is protocol-attributed (not credited to user)
        }

        if (payout > 0) {
            _transfer(address(this), user, payout);
        }

        info.lastHarvestBlock = block.number;
        emit RewardsHarvested(user, collectionAddress, payout, burnAmount);
    }

    function harvestBatch(address collectionAddress, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length <= 50, "CATA: batch limit exceeded");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _harvest(collectionAddress, _msgSender(), tokenIds[i]);
        }
    }

    // ---------------------------
    // Pending rewards view
    // ---------------------------
    function pendingRewards(address collectionAddress, address owner, uint256 tokenId) public view returns (uint256) {
        StakeInfo memory info = stakeLog[collectionAddress][owner][tokenId];
        if (!info.currentlyStaked || baseRewardRate == 0 || totalStakedNFTsCount == 0) return 0;
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) return 0;
        uint256 blocksPassed = block.number - info.lastHarvestBlock;
        uint256 rewardPerUnit = (baseRewardRate * DECIMALS_FACTOR) / (totalStakedNFTsCount == 0 ? 1 : totalStakedNFTsCount);
        uint256 rewardAmount = (blocksPassed / numberOfBlocksPerRewardUnit) * rewardPerUnit;
        return rewardAmount;
    }

    // ---------------------------
    // Voluntary burn by user (attribute to collection)
    // Transfers amount to contract then distributes fee split (burn attributed to user)
    // ---------------------------
    function burnCATA(uint256 amount, address collectionAddress) external nonReentrant whenNotPaused {
        require(amount > 0, "CATA: zero amount");
        require(balanceOf(_msgSender()) >= amount, "CATA: insufficient balance");

        _transfer(_msgSender(), address(this), amount);
        _distributeFee(amount, collectionAddress, _msgSender());
    }

    // ---------------------------
    // Quarterly bonus distribution (admin-triggered)
    // Pays top 10% of tracked burners proportionally
    // ---------------------------
    function distributeQuarterlyBonus() external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(block.number >= lastQuarterlyDistributionBlock + quarterlyBlocks, "CATA: too early for distribution");
        require(trackedCount > 0, "CATA: no tracked burners");

        uint256 pool = (treasuryBalance * bonusCapPercent) / 100;
        require(pool > 0, "CATA: pool is zero");
        require(balanceOf(address(this)) >= pool, "CATA: contract lacks pool tokens");

        uint256 eligibleCount = trackedCount / 10; // top 10%
        if (eligibleCount == 0) eligibleCount = 1; // at least 1

        // Sum weights
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < eligibleCount; i++) {
            // optional eligibility checks (minBurnForBonus/minStakeForBonus)
            if (minBurnForBonus > 0 && topBurnedAmounts[i] < minBurnForBonus) continue;
            if (minStakeForBonus > 0) {
                uint256 staked = 0;
                uint256 regCount = _registeredCollections.length();
                for (uint256 j = 0; j < regCount; j++) {
                    address coll = _registeredCollections.at(j);
                    staked += stakePortfolioByUser[coll][topBurners[i]].length;
                    if (staked >= minStakeForBonus) break;
                }
                if (staked < minStakeForBonus) continue;
            }
            totalWeight += topBurnedAmounts[i];
        }
        require(totalWeight > 0, "CATA: zero total weight among eligible");

        // Deduct pool from internal treasury accounting
        treasuryBalance -= pool;

        // Pay out proportional shares
        for (uint256 i = 0; i < eligibleCount; i++) {
            address winner = topBurners[i];
            uint256 weight = topBurnedAmounts[i];
            // re-check eligibility as above
            if (minBurnForBonus > 0 && weight < minBurnForBonus) continue;
            if (minStakeForBonus > 0) {
                uint256 staked = 0;
                uint256 regCount = _registeredCollections.length();
                for (uint256 j = 0; j < regCount; j++) {
                    address coll = _registeredCollections.at(j);
                    staked += stakePortfolioByUser[coll][winner].length;
                    if (staked >= minStakeForBonus) break;
                }
                if (staked < minStakeForBonus) continue;
            }
            uint256 share = (pool * weight) / totalWeight;
            if (share > 0) _transfer(address(this), winner, share);
        }

        lastQuarterlyDistributionBlock = block.number;
        emit BonusDistributed(pool, eligibleCount, block.timestamp);
    }

    // ---------------------------
    // Governance: create / vote / execute
    // ---------------------------
    function _isVoterEligible(address voter) internal view returns (bool) {
        if (burnedByUser[voter] > 0) return true;
        // or require at least 1 staked NFT
        uint256 regCount = _registeredCollections.length();
        for (uint256 i = 0; i < regCount; i++) {
            address coll = _registeredCollections.at(i);
            if (stakePortfolioByUser[coll][voter].length > 0) return true;
        }
        return false;
    }

    function createProposal(ProposalParam param, uint256 value) external whenNotPaused returns (uint256) {
        require(param != ProposalParam.NONE && param != ProposalParam.LAST, "CATA: invalid param");
        require(_isVoterEligible(msg.sender), "CATA: proposer not eligible");

        uint256 start = block.number;
        uint256 end = block.number + proposalDurationBlocks;
        uint256 id = proposalCount++;

        proposals[id] = Proposal({
            id: id,
            proposer: msg.sender,
            param: param,
            value: value,
            startBlock: start,
            endBlock: end,
            forVotes: 0,
            againstVotes: 0,
            executed: false
        });

        emit ProposalCreated(id, msg.sender, param, value, start, end);
        return id;
    }

    function voteOnProposal(uint256 id, bool support) external whenNotPaused {
        Proposal storage p = proposals[id];
        require(block.number >= p.startBlock && block.number <= p.endBlock, "CATA: voting not open");
        require(!hasVotedOnProposal[id][msg.sender], "CATA: already voted");
        require(_isVoterEligible(msg.sender), "CATA: not eligible");

        uint256 weight = burnedByUser[msg.sender];
        if (weight > maxVoteWeight) weight = maxVoteWeight;
        require(weight > 0, "CATA: zero weight");

        hasVotedOnProposal[id][msg.sender] = true;
        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }
        emit Voted(id, msg.sender, support, weight);
    }

    function executeProposal(uint256 id) external whenNotPaused nonReentrant {
        Proposal storage p = proposals[id];
        require(block.number > p.endBlock, "CATA: voting not ended");
        require(!p.executed, "CATA: already executed");
        require(p.forVotes >= quorumVotes && p.forVotes > p.againstVotes, "CATA: quorum not met or failed");

        // Apply safe param changes
        if (p.param == ProposalParam.SET_BASE_REWARD_RATE) baseRewardRate = p.value;
        else if (p.param == ProposalParam.SET_BONUS_CAP_PERCENT) bonusCapPercent = p.value;
        else if (p.param == ProposalParam.SET_EMISSION_CAP) emissionCap = p.value;
        else if (p.param == ProposalParam.SET_MINTING_ENABLED) mintingEnabled = (p.value != 0);
        else if (p.param == ProposalParam.SET_QUARTERLY_BLOCKS) quarterlyBlocks = p.value;
        else if (p.param == ProposalParam.SET_COLLECTION_REGISTRATION_FEE) collectionRegistrationFee = p.value;
        else if (p.param == ProposalParam.SET_UNSTAKE_BURN_FEE) unstakeBurnFee = p.value;
        else if (p.param == ProposalParam.SET_PROPOSAL_DURATION_BLOCKS) proposalDurationBlocks = p.value;
        else if (p.param == ProposalParam.SET_QUORUM_VOTES) quorumVotes = p.value;
        else if (p.param == ProposalParam.SET_MAX_VOTE_WEIGHT) maxVoteWeight = p.value;
        else revert("CATA: unsupported param");

        p.executed = true;
        emit ProposalExecuted(id, p.param, p.value);
    }

    // ---------------------------
    // Admin-only setters & utilities
    // ---------------------------
    function setInitialHarvestBurnFeeRate(uint256 rate) external onlyAdmin { require(rate <= 100, "CATA: >100"); initialHarvestBurnFeeRate = rate; }
    function setHarvestRateAdjustmentFactor(uint256 v) external onlyAdmin { require(v > 0, "CATA: >0"); harvestRateAdjustmentFactor = v; }
    function setTermDurationBlocks(uint256 v) external onlyAdmin { termDurationBlocks = v; }
    function setStakingCooldownBlocks(uint256 v) external onlyAdmin { stakingCooldownBlocks = v; }
    function setRewardRateIncrementPerNFT(uint256 v) external onlyAdmin { rewardRateIncrementPerNFT = v; }
    function setWelcomeBonusParams(uint256 baseRate, uint256 incrementPerNFT) external onlyAdmin { welcomeBonusBaseRate = baseRate; welcomeBonusIncrementPerNFT = incrementPerNFT; }
    function setQuarterlyParams(uint256 _quarterlyBlocks, uint256 _bonusCapPercent, uint256 _minBurnForBonus, uint256 _minStakeForBonus) external onlyAdmin {
        quarterlyBlocks = _quarterlyBlocks;
        bonusCapPercent = _bonusCapPercent;
        minBurnForBonus = _minBurnForBonus;
        minStakeForBonus = _minStakeForBonus;
    }
    function setProposalControls(uint256 _proposalDurationBlocks, uint256 _quorumVotes, uint256 _maxVoteWeight) external onlyAdmin {
        proposalDurationBlocks = _proposalDurationBlocks;
        quorumVotes = _quorumVotes;
        maxVoteWeight = _maxVoteWeight;
    }
    function setCollectionRegistrationFee(uint256 fee) external onlyAdmin { collectionRegistrationFee = fee; }
    function setMintingEnabled(bool flag) external onlyAdmin { mintingEnabled = flag; }
    function setEmissionCap(uint256 cap) external onlyAdmin { emissionCap = cap; }

    function pause() external onlyAdmin { _pause(); }
    function unpause() external onlyAdmin { _unpause(); }

    // ---------------------------
    // Leaderboard getter
    // ---------------------------
    function getTopBurners(uint256 n) external view returns (address[] memory addrs, uint256[] memory amounts) {
        if (n > trackedCount) n = trackedCount;
        addrs = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            addrs[i] = topBurners[i];
            amounts[i] = topBurnedAmounts[i];
        }
    }

    // ---------------------------
    // Registered collection getter
    // ---------------------------
    function getRegisteredCollections() external view returns (address[] memory arr) {
        uint256 n = _registeredCollections.length();
        arr = new address[](n);
        for (uint256 i = 0; i < n; i++) arr[i] = _registeredCollections.at(i);
    }

    // ---------------------------
    // Rescue utilities (admin)
    // ---------------------------
    function rescueERC721(address nft, uint256 tokenId, address to) external onlyAdmin {
        IERC721(nft).safeTransferFrom(address(this), to, tokenId);
    }

    function rescueERC20(address to, uint256 amount) external onlyAdmin {
        require(to != address(0), "CATA: invalid to");
        _transfer(address(this), to, amount);
    }

    // ---------------------------
    // ERC721 Receiver
    // ---------------------------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
