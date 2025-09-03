// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*
    Catalyst NFT Staking Protocol
    - Two-tier collections: VERIFIED vs UNVERIFIED (junk/unproven)
    - Unverified pay base fee + SURCHARGE ESCROW (refundable on upgrade)
    - Tier upgrade via governance if objective criteria are met
    - Escrow forfeit if not upgraded before deadline (anti-spam)
    - Top-% (not Top-10) governance eligibility by burned CATA
    - Per-collection vote cap & stake-age requirement for voting
    - Dynamic registration fees by declared supply bracket
    - 20,000 stake cap per collection
    NOTE: This code is large; run comprehensive tests and a professional audit.
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CatalystNFTStaking is ERC20, AccessControl, IERC721Receiver, ReentrancyGuard, Pausable {
    // ---------- Roles ----------
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // ---------- Governance constants ----------
    uint256 public constant WEIGHT_SCALE = 1e18;
    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public constant MAX_STAKE_PER_COLLECTION = 20000;

    // ---------- Tiers ----------
    enum CollectionTier { UNVERIFIED, VERIFIED }

    // ---------- Proposals ----------
    enum ProposalType {
        BASE_REWARD,
        HARVEST_FEE,
        UNSTAKE_FEE,
        REGISTRATION_FEE_FALLBACK,
        TREASURY_SPLIT,
        VOTING_PARAM,
        TIER_UPGRADE // NEW: upgrade collection from UNVERIFIED -> VERIFIED
    }

    struct Proposal {
        ProposalType pType;
        uint8 paramTarget;              // for VOTING_PARAM
        uint256 newValue;               // generic value
        address collectionAddress;      // context for TIER_UPGRADE or fee targeting
        address proposer;
        uint256 startBlock;
        uint256 endBlock;
        uint256 votesScaled;            // accumulated votes
        bool executed;
    }

    // ---------- Collection config ----------
    struct CollectionConfig {
        uint256 totalStaked;
        uint256 totalStakers;
        bool registered;
        uint256 declaredSupply;
    }

    struct StakeInfo {
        uint256 stakeBlock;            // stake-age for voting
        uint256 lastHarvestBlock;
        bool currentlyStaked;
        bool isPermanent;
        uint256 unstakeDeadlineBlock;  // for term stakes
    }

    struct CollectionMeta {
        CollectionTier tier;
        address registrant;            // who paid registration fee
        uint256 surchargeEscrow;       // locked extra CATA for UNVERIFIED registration
        uint256 registeredAtBlock;     // for min-age checks
        uint256 lastTierProposalBlock; // to rate-limit upgrade proposals
    }

    // ---------- Storage ----------
    mapping(address => CollectionConfig) public collectionConfigs;
    mapping(address => CollectionMeta)    public collectionMeta;

    mapping(address => mapping(address => mapping(uint256 => StakeInfo))) public stakeLog;
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser;
    mapping(address => mapping(uint256 => uint256)) public indexOfTokenIdInStakePortfolio;

    mapping(address => uint256) public burnedCatalystByCollection;

    // proposals
    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => mapping(address => uint256)) public proposalCollectionVotesScaled; // per-proposal per-collection cap accounting

    // registration enumeration
    address[] public registeredCollections;
    mapping(address => uint256) public registeredIndex; // 1-based; 0 means not registered

    // ---------- Tokenomics ----------
    uint256 public numberOfBlocksPerRewardUnit = 18782;
    uint256 public collectionRegistrationFee;  // legacy fallback (kept)
    uint256 public unstakeBurnFee;
    address public treasuryAddress;
    uint256 public totalStakedNFTsCount;
    uint256 public baseRewardRate;
    uint256 public initialHarvestBurnFeeRate;
    uint256 public termDurationBlocks;
    uint256 public stakingCooldownBlocks;
    uint256 public harvestRateAdjustmentFactor;
    uint256 public minBurnContributionForVote;

    // dynamic fees & rewards
    uint256 public initialCollectionFee;
    uint256 public feeMultiplier;
    uint256 public rewardRateIncrementPerNFT;
    uint256 public welcomeBonusBaseRate;
    uint256 public welcomeBonusIncrementPerNFT;

    // declared-supply fee brackets
    uint256 public SMALL_MIN_FEE = 1000 * 10**18;
    uint256 public SMALL_MAX_FEE = 5000 * 10**18;
    uint256 public MED_MIN_FEE   = 5000 * 10**18;
    uint256 public MED_MAX_FEE   = 10000 * 10**18;
    uint256 public LARGE_MIN_FEE = 10000 * 10**18;
    uint256 public LARGE_MAX_FEE_CAP = 20000 * 10**18;

    // Tier mechanics
    uint256 public unverifiedSurchargeBP = 20000; // 2x of base fee (10000 = 1x, 20000 = 2x)
    uint256 public tierUpgradeMinAgeBlocks = 200000;      // must be registered this long
    uint256 public tierUpgradeMinBurn = 50_000 * 10**18;  // must burn at least this much CATA
    uint256 public tierUpgradeMinStakers = 50;            // must have at least this many unique stakers
    uint256 public tierProposalCooldownBlocks = 30000;    // rate-limit proposals per collection
    uint256 public surchargeForfeitBlocks = 600000;       // if not upgraded by then, escrow can be forfeited

    // governance params
    address public immutable deployerAddress;
    uint256 public deployerFeeShareRate; // percent 0..100

    address[] public topCollections;  // dynamic Top-% by burned CATA
    uint256 public topPercent = 10;   // eligible = max(1, N * topPercent / 100)
    uint256 public minVotesRequiredScaled = 3 * WEIGHT_SCALE;
    uint256 public votingDurationBlocks = 46000;
    uint256 public smallCollectionVoteWeightScaled = (WEIGHT_SCALE * 50) / 100; // 0.5 vote
    uint256 public maxBaseRewardRate = type(uint256).max;

    // anti-collusion & voter quality
    uint256 public collectionVoteCapPercent = 70; // % of required votes a single collection may contribute per proposal
    uint256 public minStakeAgeForVoting = 100;    // blocks

    // ---------- Events ----------
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payoutAmount, uint256 burnedAmount);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);

    event CollectionAdded(address indexed collection, uint256 declaredSupply, uint256 baseFee, uint256 surchargeEscrow, CollectionTier tier);
    event CollectionRemoved(address indexed collection);

    event PermanentStakeFeePaid(address indexed staker, uint256 feeAmount);

    event ProposalCreated(bytes32 indexed id, ProposalType pType, uint8 paramTarget, address indexed collection, address indexed proposer, uint256 newValue, uint256 startBlock, uint256 endBlock);
    event VoteCast(bytes32 indexed id, address indexed voter, uint256 weightScaled, address attributedCollection);
    event ProposalExecuted(bytes32 indexed id, uint256 appliedValue);

    event TierUpgraded(address indexed collection, address indexed registrant, uint256 escrowRefunded);
    event TierProposalRejected(address indexed collection);
    event EscrowForfeited(address indexed collection, uint256 amountToTreasury, uint256 amountBurned);

    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event EmergencyWithdrawnERC20(address token, address to, uint256 amount);
    event RescuedERC721(address token, uint256 tokenId, address to);

    // Optional param update events
    event BaseRewardRateUpdated(uint256 oldValue, uint256 newValue);
    event HarvestFeeUpdated(uint256 oldValue, uint256 newValue);
    event UnstakeFeeUpdated(uint256 oldValue, uint256 newValue);
    event RegistrationFeeUpdated(uint256 oldValue, uint256 newValue);
    event TreasurySplitUpdated(uint256 oldValue, uint256 newValue);
    event VotingParamUpdated(uint8 target, uint256 oldValue, uint256 newValue);

    constructor(
        address _owner,
        address _treasury,
        uint256 _initialCollectionFee,
        uint256 _feeMultiplier,
        uint256 _rewardRateIncrementPerNFT,
        uint256 _welcomeBonusBaseRate,
        uint256 _welcomeBonusIncrementPerNFT,
        uint256 _initialHarvestBurnFeeRate,
        uint256 _termDurationBlocks,
        uint256 _collectionRegistrationFeeFallback,
        uint256 _unstakeBurnFee,
        uint256 _stakingCooldownBlocks,
        uint256 _harvestRateAdjustmentFactor,
        uint256 _minBurnContributionForVote,
        uint256 _initialDeployerSharePercent
    ) ERC20("Catalyst", "CATA") {
        require(_owner != address(0) && _treasury != address(0), "CATA: bad addr");
        require(_initialDeployerSharePercent <= 100, "CATA: share >100");

        _mint(_owner, 25_185_000 * 10**18);

        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        _setupRole(CONTRACT_ADMIN_ROLE, _owner);

        treasuryAddress = _treasury;
        deployerAddress = _owner;

        initialCollectionFee = _initialCollectionFee;
        feeMultiplier = _feeMultiplier;
        rewardRateIncrementPerNFT = _rewardRateIncrementPerNFT;
        welcomeBonusBaseRate = _welcomeBonusBaseRate;
        welcomeBonusIncrementPerNFT = _welcomeBonusIncrementPerNFT;
        initialHarvestBurnFeeRate = _initialHarvestBurnFeeRate;
        termDurationBlocks = _termDurationBlocks;
        collectionRegistrationFee = _collectionRegistrationFeeFallback;
        unstakeBurnFee = _unstakeBurnFee;
        stakingCooldownBlocks = _stakingCooldownBlocks;
        harvestRateAdjustmentFactor = _harvestRateAdjustmentFactor;
        minBurnContributionForVote = _minBurnContributionForVote;

        deployerFeeShareRate = _initialDeployerSharePercent;
    }

    // ---------- Modifiers ----------
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: cooldown");
        _;
    }
    mapping(address => uint256) public lastStakingBlock;

    // ---------- Registration helpers ----------
    function _isRegistered(address collection) internal view returns (bool) {
        return registeredIndex[collection] != 0;
    }
    function registeredCount() public view returns (uint256) { return registeredCollections.length; }

    function eligibleCount() public view returns (uint256) {
        uint256 total = registeredCollections.length;
        if (total == 0) return 0;
        uint256 count = (total * topPercent) / 100;
        if (count == 0) count = 1;
        return count;
    }

    // ---------- Fee curves ----------
    function _calculateRegistrationBaseFee(uint256 declaredSupply) internal view returns (uint256) {
        require(declaredSupply >= 1, "CATA: declared>=1");
        if (declaredSupply <= 5000) {
            uint256 numerator = declaredSupply * (SMALL_MAX_FEE - SMALL_MIN_FEE);
            return SMALL_MIN_FEE + (numerator / 5000);
        } else if (declaredSupply <= 10000) {
            uint256 numerator = (declaredSupply - 5000) * (MED_MAX_FEE - MED_MIN_FEE);
            return MED_MIN_FEE + (numerator / 5000);
        } else {
            uint256 extra = declaredSupply - 10000;
            uint256 range = 10000;
            if (extra >= range) return LARGE_MAX_FEE_CAP;
            uint256 numerator = extra * (LARGE_MAX_FEE_CAP - LARGE_MIN_FEE);
            return LARGE_MIN_FEE + (numerator / range);
        }
    }

    function _applyTierSurcharge(address collection, uint256 baseFee) internal view returns (uint256 feeToPay, uint256 surchargeAmount) {
        CollectionTier tier = collectionMeta[collection].tier;
        uint256 multBP = (tier == CollectionTier.UNVERIFIED) ? unverifiedSurchargeBP : 10000; // basis points
        uint256 total = (baseFee * multBP) / 10000;
        feeToPay = total;
        surchargeAmount = (multBP > 10000) ? (total - baseFee) : 0;
    }

    // ---------- Collection registration (admin-only) ----------
    function setCollectionConfig(address collection, uint256 declaredMaxSupply, CollectionTier tier) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(collection != address(0), "CATA: bad addr");
        require(!_isRegistered(collection), "CATA: already reg");
        require(declaredMaxSupply >= 1, "CATA: supply>=1");
        require(uint8(tier) <= 1, "CATA: tier");

        uint256 baseFee = _calculateRegistrationBaseFee(declaredMaxSupply);
        (uint256 totalFee, uint256 surcharge) = _applyTierSurcharge(collection, baseFee);
        require(balanceOf(_msgSender()) >= totalFee, "CATA: insufficient CATA");

        // Process base fee normally (burn 90% of base, rest to treasury/deployer)
        uint256 baseBurn = (baseFee * 90) / 100;
        _burn(_msgSender(), baseBurn);
        burnedCatalystByCollection[collection] += baseBurn;

        uint256 baseRemainder = baseFee - baseBurn;
        uint256 deployerShare = (baseRemainder * deployerFeeShareRate) / 100;
        uint256 communityShare = baseRemainder - deployerShare;
        _transfer(_msgSender(), deployerAddress, deployerShare);
        _transfer(_msgSender(), treasuryAddress, communityShare);

        // Surcharge escrow (if UNVERIFIED): lock it on contract (not burned)
        uint256 escrowAmt = 0;
        if (surcharge > 0) {
            // move surcharge from registrant to contract as escrow
            _transfer(_msgSender(), address(this), surcharge);
            escrowAmt = surcharge;
        }

        // register
        registeredCollections.push(collection);
        registeredIndex[collection] = registeredCollections.length;

        collectionConfigs[collection] = CollectionConfig({
            totalStaked: 0,
            totalStakers: 0,
            registered: true,
            declaredSupply: declaredMaxSupply
        });

        collectionMeta[collection] = CollectionMeta({
            tier: tier,
            registrant: _msgSender(),
            surchargeEscrow: escrowAmt,
            registeredAtBlock: block.number,
            lastTierProposalBlock: 0
        });

        _updateTopCollectionsOnBurn(collection); // cheap incremental
        _maybeRebuildTopCollections();           // adjust list size if eligibleCount grew

        emit CollectionAdded(collection, declaredMaxSupply, baseFee, escrowAmt, tier);
    }

    function removeCollection(address collection) external onlyRole(CONTRACT_ADMIN_ROLE) whenNotPaused {
        require(collectionConfigs[collection].registered, "CATA: not reg");
        collectionConfigs[collection].registered = false;

        // remove from registeredCollections
        uint256 idx = registeredIndex[collection];
        if (idx != 0) {
            uint256 i = idx - 1;
            uint256 last = registeredCollections.length - 1;
            if (i != last) {
                address lastAddr = registeredCollections[last];
                registeredCollections[i] = lastAddr;
                registeredIndex[lastAddr] = i + 1;
            }
            registeredCollections.pop();
            registeredIndex[collection] = 0;
        }

        // drop from topCollections
        for (uint256 t = 0; t < topCollections.length; t++) {
            if (topCollections[t] == collection) {
                for (uint256 j = t; j + 1 < topCollections.length; j++) {
                    topCollections[j] = topCollections[j + 1];
                }
                topCollections.pop();
                break;
            }
        }

        emit CollectionRemoved(collection);
    }

    // ---------- Tier Upgrade / Escrow Forfeit (through governance) ----------
    function _eligibleForTierUpgrade(address collection) internal view returns (bool) {
        CollectionMeta memory m = collectionMeta[collection];
        if (m.tier != CollectionTier.UNVERIFIED) return false;
        if (block.number < m.registeredAtBlock + tierUpgradeMinAgeBlocks) return false;
        if (burnedCatalystByCollection[collection] < tierUpgradeMinBurn) return false;
        if (collectionConfigs[collection].totalStakers < tierUpgradeMinStakers) return false;
        return true;
    }

    function forfeitEscrowIfExpired(address collection) external onlyRole(CONTRACT_ADMIN_ROLE) {
        // If still UNVERIFIED and past deadline, escrow is forfeited: 50% burned, 50% to treasury
        CollectionMeta storage m = collectionMeta[collection];
        require(collectionConfigs[collection].registered, "CATA: not reg");
        require(m.tier == CollectionTier.UNVERIFIED, "CATA: already verified");
        require(block.number >= m.registeredAtBlock + surchargeForfeitBlocks, "CATA: not expired");
        uint256 amt = m.surchargeEscrow;
        require(amt > 0, "CATA: no escrow");

        // split: 50% burn, 50% treasury
        uint256 toBurn = amt / 2;
        uint256 toTreasury = amt - toBurn;
        _burn(address(this), toBurn);
        _transfer(address(this), treasuryAddress, toTreasury);
        m.surchargeEscrow = 0;

        emit EscrowForfeited(collection, toTreasury, toBurn);
    }

    // ---------- Staking ----------
    function termStake(address collection, uint256 tokenId) public nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collection].registered, "CATA: not reg");
        require(collectionConfigs[collection].totalStaked < MAX_STAKE_PER_COLLECTION, "CATA: cap 20k");

        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collection][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        info.stakeBlock = block.number;
        info.lastHarvestBlock = block.number;
        info.currentlyStaked = true;
        info.isPermanent = false;
        info.unstakeDeadlineBlock = block.number + termDurationBlocks;

        CollectionConfig storage cfg = collectionConfigs[collection];
        if (stakePortfolioByUser[collection][_msgSender()].length == 0) cfg.totalStakers += 1;
        cfg.totalStaked += 1;

        totalStakedNFTsCount += 1;
        baseRewardRate += rewardRateIncrementPerNFT;

        stakePortfolioByUser[collection][_msgSender()].push(tokenId);
        indexOfTokenIdInStakePortfolio[collection][tokenId] = stakePortfolioByUser[collection][_msgSender()].length - 1;

        // welcome bonus
        uint256 dynamicWelcome = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
        _mint(_msgSender(), dynamicWelcome);

        lastStakingBlock[_msgSender()] = block.number;
        emit NFTStaked(_msgSender(), collection, tokenId);
    }

    function permanentStake(address collection, uint256 tokenId) public nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collection].registered, "CATA: not reg");
        require(collectionConfigs[collection].totalStaked < MAX_STAKE_PER_COLLECTION, "CATA: cap 20k");

        uint256 fee = _getDynamicPermanentStakeFee();
        require(balanceOf(_msgSender()) >= fee, "CATA: insufficient CATA");

        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collection][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        // burn 90% of fee, route remainder to treasury/deployer
        uint256 burnAmt = (fee * 90) / 100;
        _burn(_msgSender(), burnAmt);
        burnedCatalystByCollection[collection] += burnAmt;
        _updateTopCollectionsOnBurn(collection);

        uint256 rem = fee - burnAmt;
        uint256 dep = (rem * deployerFeeShareRate) / 100;
        uint256 tre = rem - dep;
        _transfer(_msgSender(), deployerAddress, dep);
        _transfer(_msgSender(), treasuryAddress, tre);

        info.stakeBlock = block.number;
        info.lastHarvestBlock = block.number;
        info.currentlyStaked = true;
        info.isPermanent = true;
        info.unstakeDeadlineBlock = 0;

        CollectionConfig storage cfg = collectionConfigs[collection];
        if (stakePortfolioByUser[collection][_msgSender()].length == 0) cfg.totalStakers += 1;
        cfg.totalStaked += 1;

        totalStakedNFTsCount += 1;
        baseRewardRate += rewardRateIncrementPerNFT;

        stakePortfolioByUser[collection][_msgSender()].push(tokenId);
        indexOfTokenIdInStakePortfolio[collection][tokenId] = stakePortfolioByUser[collection][_msgSender()].length - 1;

        // welcome bonus
        uint256 dynamicWelcome = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
        _mint(_msgSender(), dynamicWelcome);

        lastStakingBlock[_msgSender()] = block.number;
        emit PermanentStakeFeePaid(_msgSender(), fee);
        emit NFTStaked(_msgSender(), collection, tokenId);
    }

    function unstake(address collection, uint256 tokenId) public nonReentrant whenNotPaused {
        StakeInfo storage info = stakeLog[collection][_msgSender()][tokenId];
        require(info.currentlyStaked, "CATA: not staked");
        if (!info.isPermanent) require(block.number >= info.unstakeDeadlineBlock, "CATA: term active");

        _harvest(collection, _msgSender(), tokenId);
        require(balanceOf(_msgSender()) >= unstakeBurnFee, "CATA: fee");
        _burn(_msgSender(), unstakeBurnFee);

        info.currentlyStaked = false;

        uint256[] storage port = stakePortfolioByUser[collection][_msgSender()];
        uint256 idx = indexOfTokenIdInStakePortfolio[collection][tokenId];
        uint256 last = port.length - 1;
        if (idx != last) {
            uint256 lastTokenId = port[last];
            port[idx] = lastTokenId;
            indexOfTokenIdInStakePortfolio[collection][lastTokenId] = idx;
        }
        port.pop();
        delete indexOfTokenIdInStakePortfolio[collection][tokenId];

        IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);

        CollectionConfig storage cfg = collectionConfigs[collection];
        if (stakePortfolioByUser[collection][_msgSender()].length == 0) cfg.totalStakers -= 1;
        cfg.totalStaked -= 1;

        if (baseRewardRate >= rewardRateIncrementPerNFT) baseRewardRate -= rewardRateIncrementPerNFT;

        emit NFTUnstaked(_msgSender(), collection, tokenId);
    }

    // ---------- Harvest ----------
    function _harvest(address collection, address user, uint256 tokenId) internal {
        StakeInfo storage info = stakeLog[collection][user][tokenId];
        uint256 reward = pendingRewards(collection, user, tokenId);
        if (reward == 0) return;

        uint256 feeRate = _getDynamicHarvestBurnFeeRate();
        uint256 burnAmt = (reward * feeRate) / 100;
        uint256 payout = reward - burnAmt;

        _mint(user, reward);
        if (burnAmt > 0) {
            _burn(user, burnAmt);
            burnedCatalystByCollection[collection] += burnAmt;
            _updateTopCollectionsOnBurn(collection);
        }
        info.lastHarvestBlock = block.number;

        emit RewardsHarvested(user, collection, payout, burnAmt);
    }

    function harvestBatch(address collection, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0 && tokenIds.length <= MAX_HARVEST_BATCH, "CATA: batch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _harvest(collection, _msgSender(), tokenIds[i]);
        }
    }

    function pendingRewards(address collection, address owner, uint256 tokenId) public view returns (uint256) {
        StakeInfo memory info = stakeLog[collection][owner][tokenId];
        if (!info.currentlyStaked || baseRewardRate == 0 || totalStakedNFTsCount == 0) return 0;
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) return 0;

        uint256 blocksPassed = block.number - info.lastHarvestBlock;
        uint256 numerator = blocksPassed * baseRewardRate;
        uint256 rewardAmount = (numerator / numberOfBlocksPerRewardUnit) / totalStakedNFTsCount;
        return rewardAmount;
    }

    // ---------- Governance ----------
    function propose(
        ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collectionContext
    ) external whenNotPaused returns (bytes32) {
        // must be eligible proposer: staker in any top-% collection (stake-age) OR staker in collectionContext that meets burn threshold
        bool eligible = _isEligibleProposer(_msgSender(), collectionContext);
        require(eligible, "CATA: proposer not eligible");

        // rate-limit tier proposals per collection
        if (pType == ProposalType.TIER_UPGRADE) {
            require(collectionContext != address(0), "CATA: collection req");
            CollectionMeta storage m = collectionMeta[collectionContext];
            require(block.number >= m.lastTierProposalBlock + tierProposalCooldownBlocks, "CATA: tier cooldown");
            m.lastTierProposalBlock = block.number;
        }

        bytes32 id = keccak256(abi.encodePacked(uint256(pType), paramTarget, newValue, collectionContext, block.number, _msgSender()));
        Proposal storage p = proposals[id];
        require(p.startBlock == 0, "CATA: exists");

        p.pType = pType;
        p.paramTarget = paramTarget;
        p.newValue = newValue;
        p.collectionAddress = collectionContext;
        p.proposer = _msgSender();
        p.startBlock = block.number;
        p.endBlock = block.number + votingDurationBlocks;

        emit ProposalCreated(id, pType, paramTarget, collectionContext, _msgSender(), newValue, p.startBlock, p.endBlock);
        return id;
    }

    function vote(bytes32 id) external whenNotPaused {
        Proposal storage p = proposals[id];
        require(p.startBlock != 0, "CATA: not found");
        require(block.number >= p.startBlock && block.number <= p.endBlock, "CATA: closed");
        require(!p.executed, "CATA: executed");
        require(!hasVoted[id][_msgSender()], "CATA: voted");

        (uint256 weight, address attributedCollection) = _votingWeight(_msgSender(), p.collectionAddress);
        require(weight > 0, "CATA: not eligible to vote");

        // per-collection cap
        uint256 cap = (minVotesRequiredScaled * collectionVoteCapPercent) / 100;
        uint256 cur = proposalCollectionVotesScaled[id][attributedCollection];
        require(cur + weight <= cap, "CATA: collection cap");

        hasVoted[id][_msgSender()] = true;
        p.votesScaled += weight;
        proposalCollectionVotesScaled[id][attributedCollection] = cur + weight;

        emit VoteCast(id, _msgSender(), weight, attributedCollection);
    }

    function executeProposal(bytes32 id) external whenNotPaused nonReentrant {
        Proposal storage p = proposals[id];
        require(p.startBlock != 0, "CATA: not found");
        require(block.number > p.endBlock, "CATA: voting");
        require(!p.executed, "CATA: executed");
        require(p.votesScaled >= minVotesRequiredScaled, "CATA: quorum");

        if (p.pType == ProposalType.BASE_REWARD) {
            uint256 old = baseRewardRate;
            baseRewardRate = p.newValue > maxBaseRewardRate ? maxBaseRewardRate : p.newValue;
            emit BaseRewardRateUpdated(old, baseRewardRate);
            emit ProposalExecuted(id, baseRewardRate);
        } else if (p.pType == ProposalType.HARVEST_FEE) {
            require(p.newValue <= 100, "CATA: fee>100");
            uint256 old = initialHarvestBurnFeeRate;
            initialHarvestBurnFeeRate = p.newValue;
            emit HarvestFeeUpdated(old, p.newValue);
            emit ProposalExecuted(id, p.newValue);
        } else if (p.pType == ProposalType.UNSTAKE_FEE) {
            uint256 old = unstakeBurnFee;
            unstakeBurnFee = p.newValue;
            emit UnstakeFeeUpdated(old, p.newValue);
            emit ProposalExecuted(id, p.newValue);
        } else if (p.pType == ProposalType.REGISTRATION_FEE_FALLBACK) {
            uint256 old = collectionRegistrationFee;
            collectionRegistrationFee = p.newValue;
            emit RegistrationFeeUpdated(old, p.newValue);
            emit ProposalExecuted(id, p.newValue);
        } else if (p.pType == ProposalType.TREASURY_SPLIT) {
            require(p.newValue <= 100, "CATA: >100");
            uint256 old = deployerFeeShareRate;
            deployerFeeShareRate = p.newValue;
            emit TreasurySplitUpdated(old, p.newValue);
            emit ProposalExecuted(id, p.newValue);
        } else if (p.pType == ProposalType.VOTING_PARAM) {
            uint8 t = p.paramTarget;
            if (t == 0) { uint256 old = minVotesRequiredScaled; minVotesRequiredScaled = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else if (t == 1) { uint256 old = votingDurationBlocks; votingDurationBlocks = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else if (t == 2) { require(p.newValue <= WEIGHT_SCALE, "CATA: >1"); uint256 old = smallCollectionVoteWeightScaled; smallCollectionVoteWeightScaled = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else if (t == 3) { uint256 old = minBurnContributionForVote; minBurnContributionForVote = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else if (t == 4) { uint256 old = maxBaseRewardRate; maxBaseRewardRate = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else if (t == 5) { uint256 old = numberOfBlocksPerRewardUnit; numberOfBlocksPerRewardUnit = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else if (t == 6) { uint256 old = collectionVoteCapPercent; collectionVoteCapPercent = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else if (t == 7) { uint256 old = minStakeAgeForVoting; minStakeAgeForVoting = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else if (t == 8) { uint256 old = topPercent; require(p.newValue>=1 && p.newValue<=100, "CATA: 1..100"); topPercent = p.newValue; _rebuildTopCollections(); emit VotingParamUpdated(t, old, p.newValue); }
            else { revert("CATA: unknown target"); }
            emit ProposalExecuted(id, p.newValue);
        } else if (p.pType == ProposalType.TIER_UPGRADE) {
            address c = p.collectionAddress;
            require(_eligibleForTierUpgrade(c), "CATA: prereq fail");
            CollectionMeta storage m = collectionMeta[c];
            require(m.tier == CollectionTier.UNVERIFIED, "CATA: already verified");

            // Upgrade and refund escrow
            m.tier = CollectionTier.VERIFIED;
            uint256 refund = m.surchargeEscrow;
            m.surchargeEscrow = 0;
            if (refund > 0) {
                // send escrow back to original registrant
                _transfer(address(this), m.registrant, refund);
            }
            emit TierUpgraded(c, m.registrant, refund);
            emit ProposalExecuted(id, 1);
        } else {
            revert("CATA: unknown proposal");
        }

        p.executed = true;
    }

    // ---------- Voting helpers ----------
    function _isEligibleProposer(address user, address collectionContext) internal view returns (bool) {
        // Full eligibility if staker in any top-% collection with stake-age
        for (uint256 i = 0; i < topCollections.length; i++) {
            address coll = topCollections[i];
            uint256[] storage port = stakePortfolioByUser[coll][user];
            if (port.length == 0) continue;
            for (uint256 j = 0; j < port.length; j++) {
                StakeInfo storage si = stakeLog[coll][user][port[j]];
                if (si.currentlyStaked && block.number >= si.stakeBlock + minStakeAgeForVoting) return true;
            }
        }
        // Fallback: staker in collectionContext that burned >= threshold
        if (collectionContext != address(0) && burnedCatalystByCollection[collectionContext] >= minBurnContributionForVote) {
            uint256[] storage p = stakePortfolioByUser[collectionContext][user];
            if (p.length > 0) {
                for (uint256 k = 0; k < p.length; k++) {
                    StakeInfo storage si2 = stakeLog[collectionContext][user][p[k]];
                    if (si2.currentlyStaked && block.number >= si2.stakeBlock + minStakeAgeForVoting) return true;
                }
            }
        }
        return false;
    }

    function _votingWeight(address voter, address context) internal view returns (uint256 weight, address attributedCollection) {
        // Full weight if voter stakes in a top-% collection with stake-age
        for (uint256 i = 0; i < topCollections.length; i++) {
            address coll = topCollections[i];
            uint256[] storage port = stakePortfolioByUser[coll][voter];
            if (port.length == 0) continue;
            bool oldStake = false;
            for (uint256 j = 0; j < port.length; j++) {
                StakeInfo storage si = stakeLog[coll][voter][port[j]];
                if (si.currentlyStaked && block.number >= si.stakeBlock + minStakeAgeForVoting) { oldStake = true; break; }
            }
            if (oldStake) return (WEIGHT_SCALE, coll);
        }
        // Fractional weight via context collection (burn threshold + stake-age)
        if (context != address(0) && burnedCatalystByCollection[context] >= minBurnContributionForVote) {
            uint256[] storage p = stakePortfolioByUser[context][voter];
            if (p.length > 0) {
                bool ok = false;
                for (uint256 k = 0; k < p.length; k++) {
                    StakeInfo storage si2 = stakeLog[context][voter][p[k]];
                    if (si2.currentlyStaked && block.number >= si2.stakeBlock + minStakeAgeForVoting) { ok = true; break; }
                }
                if (ok) return (smallCollectionVoteWeightScaled, context);
            }
        }
        return (0, address(0));
    }

    // ---------- Top-% leaderboard maintenance ----------
    function _updateTopCollectionsOnBurn(address collection) internal {
        if (!_isRegistered(collection)) return;

        uint256 b = burnedCatalystByCollection[collection];
        // remove if exists
        for (uint256 i = 0; i < topCollections.length; i++) {
            if (topCollections[i] == collection) {
                for (uint256 j = i; j + 1 < topCollections.length; j++) topCollections[j] = topCollections[j + 1];
                topCollections.pop();
                break;
            }
        }
        // insert sorted desc
        bool ins = false;
        for (uint256 i = 0; i < topCollections.length; i++) {
            if (b > burnedCatalystByCollection[topCollections[i]]) {
                topCollections.push(topCollections[topCollections.length - 1]);
                for (uint256 k = topCollections.length - 1; k > i; k--) topCollections[k] = topCollections[k - 1];
                topCollections[i] = collection;
                ins = true;
                break;
            }
        }
        if (!ins) topCollections.push(collection);

        // trim to eligibleCount
        uint256 ec = eligibleCount();
        while (topCollections.length > ec) topCollections.pop();
    }

    function _rebuildTopCollections() internal {
        uint256 total = registeredCollections.length;
        delete topCollections;
        if (total == 0) return;

        uint256 ec = eligibleCount();
        if (ec > total) ec = total;

        // selection of top ec by burned
        bool[] memory picked = new bool[](total);
        for (uint256 s = 0; s < ec; s++) {
            uint256 maxB = 0; uint256 maxIdx = 0; bool found = false;
            for (uint256 i = 0; i < total; i++) {
                if (picked[i]) continue;
                address cand = registeredCollections[i];
                uint256 bb = burnedCatalystByCollection[cand];
                if (!found || bb > maxB) { maxB = bb; maxIdx = i; found = true; }
            }
            if (found) { picked[maxIdx] = true; topCollections.push(registeredCollections[maxIdx]); }
        }
    }

    function _maybeRebuildTopCollections() internal {
        uint256 ec = eligibleCount();
        if (ec > topCollections.length) _rebuildTopCollections();
        else if (topCollections.length == 0 && registeredCollections.length > 0) _rebuildTopCollections();
    }

    // ---------- Admin setters ----------
    function setTopPercent(uint256 p) external onlyRole(CONTRACT_ADMIN_ROLE) { require(p>=1 && p<=100,"CATA:1..100"); topPercent=p; _rebuildTopCollections(); }
    function setCollectionVoteCapPercent(uint256 p) external onlyRole(CONTRACT_ADMIN_ROLE) { require(p>=1 && p<=100,"CATA:1..100"); collectionVoteCapPercent=p; }
    function setMinStakeAgeForVoting(uint256 blocks_) external onlyRole(CONTRACT_ADMIN_ROLE) { minStakeAgeForVoting=blocks_; }
    function setMaxBaseRewardRate(uint256 cap_) external onlyRole(CONTRACT_ADMIN_ROLE) { maxBaseRewardRate=cap_; }

    function setWelcomeBonusBaseRate(uint256 v) external onlyRole(CONTRACT_ADMIN_ROLE) { welcomeBonusBaseRate=v; }
    function setWelcomeBonusIncrementPerNFT(uint256 v) external onlyRole(CONTRACT_ADMIN_ROLE) { welcomeBonusIncrementPerNFT=v; }
    function setHarvestRateAdjustmentFactor(uint256 v) external onlyRole(CONTRACT_ADMIN_ROLE) { require(v>0,"CATA:>0"); harvestRateAdjustmentFactor=v; }
    function setTermDurationBlocks(uint256 v) external onlyRole(CONTRACT_ADMIN_ROLE) { termDurationBlocks=v; }
    function setStakingCooldownBlocks(uint256 v) external onlyRole(CONTRACT_ADMIN_ROLE) { stakingCooldownBlocks=v; }

    function setRegistrationFeeBrackets(
        uint256 sMin, uint256 sMax, uint256 mMin, uint256 mMax, uint256 lMin, uint256 lCap
    ) external onlyRole(CONTRACT_ADMIN_ROLE) {
        SMALL_MIN_FEE=sMin; SMALL_MAX_FEE=sMax; MED_MIN_FEE=mMin; MED_MAX_FEE=mMax; LARGE_MIN_FEE=lMin; LARGE_MAX_FEE_CAP=lCap;
    }

    function setUnverifiedSurchargeBP(uint256 bp) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(bp >= 10000, "CATA: >=1x");
        unverifiedSurchargeBP = bp;
    }

    function setTierUpgradeThresholds(uint256 minAgeBlocks, uint256 minBurn, uint256 minStakers) external onlyRole(CONTRACT_ADMIN_ROLE) {
        tierUpgradeMinAgeBlocks = minAgeBlocks;
        tierUpgradeMinBurn = minBurn;
        tierUpgradeMinStakers = minStakers;
    }

    function setTierProposalCooldown(uint256 blocks_) external onlyRole(CONTRACT_ADMIN_ROLE) {
        tierProposalCooldownBlocks = blocks_;
    }

    function setSurchargeForfeitBlocks(uint256 blocks_) external onlyRole(CONTRACT_ADMIN_ROLE) {
        surchargeForfeitBlocks = blocks_;
    }

    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); emit Paused(_msgSender()); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); emit Unpaused(_msgSender()); }

    function addContractAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) { grantRole(CONTRACT_ADMIN_ROLE, admin); emit AdminAdded(admin); }
    function removeContractAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) { revokeRole(CONTRACT_ADMIN_ROLE, admin); emit AdminRemoved(admin); }

    function emergencyWithdrawERC20(address token, address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(to != address(0), "CATA: bad to"); IERC20(token).transfer(to, amount); emit EmergencyWithdrawnERC20(token, to, amount);
    }
    function rescueERC721(address token, uint256 tokenId, address to) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(to != address(0), "CATA: bad to"); IERC721(token).safeTransferFrom(address(this), to, tokenId); emit RescuedERC721(token, tokenId, to);
    }

    // ---------- Math & dynamics ----------
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y / 2 + 1; while (x < z) { z = x; x = (y / x + x) / 2; } }
        else if (y != 0) { z = 1; }
    }

    function _getDynamicPermanentStakeFee() internal view returns (uint256) {
        return initialCollectionFee + (_sqrt(totalStakedNFTsCount) * feeMultiplier);
    }

    function _getDynamicHarvestBurnFeeRate() internal view returns (uint256) {
        if (harvestRateAdjustmentFactor == 0) return initialHarvestBurnFeeRate;
        uint256 rate = initialHarvestBurnFeeRate + (baseRewardRate / harvestRateAdjustmentFactor);
        if (rate > 90) return 90;
        return rate;
    }

    // ---------- Views ----------
    function getTopCollections() external view returns (address[] memory) { return topCollections; }
    function getRegisteredCollections() external view returns (address[] memory) { return registeredCollections; }
    function getProposal(bytes32 id) external view returns (Proposal memory) { return proposals[id]; }
    function getBurnedCatalystByCollection(address c) external view returns (uint256) { return burnedCatalystByCollection[c]; }
    function getCollectionMeta(address c) external view returns (CollectionMeta memory) { return collectionMeta[c]; }

    // ---------- ERC721 Receiver ----------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
