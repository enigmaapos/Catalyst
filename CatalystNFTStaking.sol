// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*
  Catalyst NFT Staking Protocol — Top-percent governance + risk mitigations

  Additions vs prior version:
  - registeredCollections[] + registeredIndex mapping (enumerable registered collections)
  - topPercent (admin-settable) -> eligibleCount = max(1, registeredCollections.length * topPercent / 100)
  - topCollections[] sized to eligibleCount, kept sorted by burnedCatalystByCollection desc
  - _rebuildTopCollections() admin-invoked when eligibleCount increases (re-scans registeredCollections)
  - _updateTopCollectionsOnBurn() incremental insertion used on burns (cheap)
  - minStakeAgeForVoting: voters must have a stake older than this to count
  - stakeBlock in StakeInfo
  - proposalCollectionVotesScaled to cap votes coming from a single collection per proposal
  - collectionVoteCapPercent (default 70) caps per-collection contribution relative to minVotesRequiredScaled
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CatalystNFTStaking is ERC20, AccessControl, IERC721Receiver, ReentrancyGuard, Pausable {
    // Roles
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // Constants
    uint256 public constant WEIGHT_SCALE = 1e18;
    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public constant MAX_STAKE_PER_COLLECTION = 20000;

    // Proposal types (multi-parameter)
    enum ProposalType {
        BASE_REWARD,
        HARVEST_FEE,
        UNSTAKE_FEE,
        REGISTRATION_FEE,
        TREASURY_SPLIT,
        VOTING_PARAM
    }

    struct Proposal {
        ProposalType pType;
        uint8 paramTarget;
        uint256 newValue;
        address collectionAddress;
        address proposer;
        uint256 startBlock;
        uint256 endBlock;
        uint256 votesScaled;
        bool executed;
    }

    // Collection / staking storage
    struct CollectionConfig {
        uint256 totalStaked;
        uint256 totalStakers;
        bool registered;
        uint256 declaredSupply;
    }

    struct StakeInfo {
        uint256 stakeBlock;        // block where stake happened (for stake-age)
        uint256 lastHarvestBlock;
        bool currentlyStaked;
        bool isPermanent;
        uint256 unstakeDeadlineBlock;
    }

    // --- Mappings and arrays
    mapping(address => CollectionConfig) public collectionConfigs;
    mapping(address => mapping(uint256 => bool)) public welcomeBonusCollected;
    mapping(address => uint256) public lastStakingBlock;
    mapping(address => mapping(address => mapping(uint256 => StakeInfo))) public stakeLog;
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser;
    mapping(address => mapping(uint256 => uint256)) public indexOfTokenIdInStakePortfolio;
    mapping(address => uint256) public burnedCatalystByCollection;

    // proposals & votes
    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;
    // per-proposal per-collection accumulated scaled weight (to enforce per-collection cap)
    mapping(bytes32 => mapping(address => uint256)) public proposalCollectionVotesScaled;

    // registered collections enumeration
    address[] public registeredCollections;
    mapping(address => uint256) public registeredIndex; // 1-based index: 0 means not registered

    // tokenomics parameters
    uint256 public numberOfBlocksPerRewardUnit;
    uint256 public collectionRegistrationFee; // fallback
    uint256 public unstakeBurnFee;
    address public treasuryAddress;
    uint256 public totalStakedNFTsCount;
    uint256 public baseRewardRate;
    uint256 public initialHarvestBurnFeeRate;
    uint256 public termDurationBlocks;
    uint256 public stakingCooldownBlocks;
    uint256 public harvestRateAdjustmentFactor;
    uint256 public minBurnContributionForVote;

    uint256 public initialCollectionFee;
    uint256 public feeMultiplier;
    uint256 public rewardRateIncrementPerNFT;
    uint256 public welcomeBonusBaseRate;
    uint256 public welcomeBonusIncrementPerNFT;

    address public immutable deployerAddress;
    uint256 public deployerFeeShareRate; // percent 0..100

    // governance
    address[] public topCollections; // sorted descending by burnedCatalystByCollection
    uint256 public topPercent = 10; // admin-settable percent for "top X%"
    uint256 public minVotesRequiredScaled;
    uint256 public votingDurationBlocks;
    uint256 public smallCollectionVoteWeightScaled;
    uint256 public maxBaseRewardRate;

    // anti-collusion & stake-age
    uint256 public collectionVoteCapPercent = 70; // max percent of required votes a single collection may supply
    uint256 public minStakeAgeForVoting = 100; // blocks

    // registration fee bracket params
    uint256 public SMALL_MIN_FEE = 1000 * 10**18;
    uint256 public SMALL_MAX_FEE = 5000 * 10**18;
    uint256 public MED_MIN_FEE = 5000 * 10**18;
    uint256 public MED_MAX_FEE = 10000 * 10**18;
    uint256 public LARGE_MIN_FEE = 10000 * 10**18;
    uint256 public LARGE_MAX_FEE_CAP = 20000 * 10**18;

    // events (important ones included)
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payoutAmount, uint256 burnedAmount);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event CollectionAdded(address indexed collectionAddress, uint256 declaredSupply, uint256 feeCharged);
    event CollectionRemoved(address indexed collectionAddress);
    event PermanentStakeFeePaid(address indexed staker, uint256 feeAmount);
    event ProposalCreated(bytes32 indexed proposalId, ProposalType pType, uint8 paramTarget, address indexed collection, address indexed proposer, uint256 newValue, uint256 startBlock, uint256 endBlock);
    event VoteCast(bytes32 indexed proposalId, address indexed voter, uint256 weightScaled, address attributedCollection);
    event ProposalExecuted(bytes32 indexed proposalId, uint256 newValue);

    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event EmergencyWithdrawnERC20(address token, address to, uint256 amount);
    event RescuedERC721(address token, uint256 tokenId, address to);

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
        require(_treasury != address(0), "CATA: invalid treasury");
        require(_owner != address(0), "CATA: invalid owner");
        require(_initialDeployerSharePercent <= 100, "CATA: deployer share >100");

        _mint(_owner, 25_185_000 * 10 ** 18);

        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        _setupRole(CONTRACT_ADMIN_ROLE, _owner);

        numberOfBlocksPerRewardUnit = 18782;
        treasuryAddress = _treasury;
        deployerAddress = _owner;

        initialCollectionFee = _initialCollectionFee;
        feeMultiplier = _feeMultiplier;
        rewardRateIncrementPerNFT = _rewardRateIncrementPerNFT;
        welcomeBonusBaseRate = _welcomeBonusBaseRate;
        welcomeBonusIncrementPerNFT = _welcomeBonusIncrementPerNFT;
        termDurationBlocks = _termDurationBlocks;
        stakingCooldownBlocks = _stakingCooldownBlocks;

        collectionRegistrationFee = _collectionRegistrationFeeFallback;
        unstakeBurnFee = _unstakeBurnFee;
        initialHarvestBurnFeeRate = _initialHarvestBurnFeeRate;
        harvestRateAdjustmentFactor = _harvestRateAdjustmentFactor;
        minBurnContributionForVote = _minBurnContributionForVote;
        baseRewardRate = 0;

        deployerFeeShareRate = _initialDeployerSharePercent;

        // governance defaults
        minVotesRequiredScaled = 3 * WEIGHT_SCALE;
        votingDurationBlocks = 46000;
        smallCollectionVoteWeightScaled = (WEIGHT_SCALE * 50) / 100;
        maxBaseRewardRate = type(uint256).max;
    }

    // ---------- Modifiers ----------
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: cooldown not passed");
        _;
    }

    // ---------- Registration helpers ----------
    function _isRegistered(address collection) internal view returns (bool) {
        return registeredIndex[collection] != 0;
    }

    function registeredCount() public view returns (uint256) {
        return registeredCollections.length;
    }

    // calculate eligibleCount from topPercent
    function eligibleCount() public view returns (uint256) {
        uint256 total = registeredCollections.length;
        if (total == 0) return 0;
        uint256 count = (total * topPercent) / 100;
        if (count == 0) count = 1;
        return count;
    }

    // ---------- Stake functions (with stake cap) ----------
    function termStake(address collectionAddress, uint256 tokenId) public nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: not registered");
        require(collectionConfigs[collectionAddress].totalStaked < MAX_STAKE_PER_COLLECTION, "CATA: stake cap reached");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        info.stakeBlock = block.number;
        info.lastHarvestBlock = block.number;
        info.currentlyStaked = true;
        info.isPermanent = false;
        info.unstakeDeadlineBlock = block.number + termDurationBlocks;

        CollectionConfig storage config = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][_msgSender()].length == 0) {
            config.totalStakers += 1;
        }
        config.totalStaked += 1;

        totalStakedNFTsCount += 1;
        baseRewardRate += rewardRateIncrementPerNFT;

        stakePortfolioByUser[collectionAddress][_msgSender()].push(tokenId);
        indexOfTokenIdInStakePortfolio[collectionAddress][tokenId] = stakePortfolioByUser[collectionAddress][_msgSender()].length - 1;

        if (!welcomeBonusCollected[collectionAddress][tokenId]) {
            uint256 dynamicWelcomeBonus = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
            _mint(_msgSender(), dynamicWelcomeBonus);
            welcomeBonusCollected[collectionAddress][tokenId] = true;
        }

        lastStakingBlock[_msgSender()] = block.number;
        emit NFTStaked(_msgSender(), collectionAddress, tokenId);
    }

    function permanentStake(address collectionAddress, uint256 tokenId) public nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: not registered");
        require(collectionConfigs[collectionAddress].totalStaked < MAX_STAKE_PER_COLLECTION, "CATA: stake cap reached");

        uint256 currentFee = _getDynamicPermanentStakeFee();
        require(balanceOf(_msgSender()) >= currentFee, "CATA: insufficient balance");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        uint256 burnAmount = (currentFee * 90) / 100;
        _burn(_msgSender(), burnAmount);
        burnedCatalystByCollection[collectionAddress] += burnAmount;

        // update top collections incrementally
        _updateTopCollectionsOnBurn(collectionAddress);

        uint256 treasuryAmount = currentFee - burnAmount;
        uint256 deployerShare = (treasuryAmount * deployerFeeShareRate) / 100;
        uint256 communityTreasuryShare = treasuryAmount - deployerShare;

        _transfer(_msgSender(), deployerAddress, deployerShare);
        _transfer(_msgSender(), treasuryAddress, communityTreasuryShare);

        info.stakeBlock = block.number;
        info.lastHarvestBlock = block.number;
        info.currentlyStaked = true;
        info.isPermanent = true;
        info.unstakeDeadlineBlock = 0;

        CollectionConfig storage config = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][_msgSender()].length == 0) {
            config.totalStakers += 1;
        }
        config.totalStaked += 1;

        totalStakedNFTsCount += 1;
        baseRewardRate += rewardRateIncrementPerNFT;

        stakePortfolioByUser[collectionAddress][_msgSender()].push(tokenId);
        indexOfTokenIdInStakePortfolio[collectionAddress][tokenId] = stakePortfolioByUser[collectionAddress][_msgSender()].length - 1;

        if (!welcomeBonusCollected[collectionAddress][tokenId]) {
            uint256 dynamicWelcomeBonus = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
            _mint(_msgSender(), dynamicWelcomeBonus);
            welcomeBonusCollected[collectionAddress][tokenId] = true;
        }

        lastStakingBlock[_msgSender()] = block.number;
        emit PermanentStakeFeePaid(_msgSender(), currentFee);
        emit NFTStaked(_msgSender(), collectionAddress, tokenId);
    }

    function unstake(address collectionAddress, uint256 tokenId) public nonReentrant whenNotPaused {
        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(info.currentlyStaked, "CATA: not staked");

        if (!info.isPermanent) {
            require(block.number >= info.unstakeDeadlineBlock, "CATA: term not expired");
        }

        _harvest(collectionAddress, _msgSender(), tokenId);

        require(balanceOf(_msgSender()) >= unstakeBurnFee, "CATA: insufficient for unstake fee");
        _burn(_msgSender(), unstakeBurnFee);

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

        CollectionConfig storage config = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][_msgSender()].length == 0) {
            config.totalStakers -= 1;
        }
        config.totalStaked -= 1;

        if (baseRewardRate >= rewardRateIncrementPerNFT) {
            baseRewardRate -= rewardRateIncrementPerNFT;
        }

        emit NFTUnstaked(_msgSender(), collectionAddress, tokenId);
    }

    // ---------- Harvest ----------
    function _harvest(address collectionAddress, address user, uint256 tokenId) internal {
        StakeInfo storage info = stakeLog[collectionAddress][user][tokenId];
        uint256 rewardAmount = pendingRewards(collectionAddress, user, tokenId);

        if (rewardAmount > 0) {
            uint256 dynamicHarvestBurnFeeRate = _getDynamicHarvestBurnFeeRate();
            uint256 burnAmount = (rewardAmount * dynamicHarvestBurnFeeRate) / 100;
            uint256 payoutAmount = rewardAmount - burnAmount;

            _mint(user, rewardAmount);

            if (burnAmount > 0) {
                _burn(user, burnAmount);
                burnedCatalystByCollection[collectionAddress] += burnAmount;

                // update top collections incrementally
                _updateTopCollectionsOnBurn(collectionAddress);
            }

            info.lastHarvestBlock = block.number;
            emit RewardsHarvested(user, collectionAddress, payoutAmount, burnAmount);
        }
    }

    function harvestBatch(address collectionAddress, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0, "CATA: no tokenIds");
        require(tokenIds.length <= MAX_HARVEST_BATCH, "CATA: batch too large");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            _harvest(collectionAddress, _msgSender(), tokenIds[i]);
        }
    }

    // ---------- Pending rewards ----------
    function pendingRewards(address collectionAddress, address owner, uint256 tokenId) public view returns (uint256) {
        StakeInfo memory info = stakeLog[collectionAddress][owner][tokenId];
        if (!info.currentlyStaked || baseRewardRate == 0 || totalStakedNFTsCount == 0) return 0;
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) return 0;

        uint256 blocksPassed = block.number - info.lastHarvestBlock;
        uint256 numerator = blocksPassed * baseRewardRate;
        uint256 rewardAmount = (numerator / numberOfBlocksPerRewardUnit) / totalStakedNFTsCount;
        return rewardAmount;
    }

    // ---------- Registration fee (tiered dynamic) ----------
    function _calculateRegistrationFee(uint256 declaredSupply) internal view returns (uint256) {
        require(declaredSupply >= 1, "CATA: declaredSupply>=1");

        if (declaredSupply <= 5000) {
            uint256 numerator = declaredSupply * (SMALL_MAX_FEE - SMALL_MIN_FEE);
            return SMALL_MIN_FEE + (numerator / 5000);
        } else if (declaredSupply <= 10000) {
            uint256 numerator = (declaredSupply - 5000) * (MED_MAX_FEE - MED_MIN_FEE);
            return MED_MIN_FEE + (numerator / 5000);
        } else {
            uint256 extra = declaredSupply - 10000;
            uint256 range = 10000;
            if (extra >= range) {
                return LARGE_MAX_FEE_CAP;
            } else {
                uint256 numerator = extra * (LARGE_MAX_FEE_CAP - LARGE_MIN_FEE);
                return LARGE_MIN_FEE + (numerator / range);
            }
        }
    }

    // ---------- Collection registration (admin-only) ----------
    function setCollectionConfig(address collectionAddress, uint256 declaredMaxSupply) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(collectionAddress != address(0), "CATA: invalid address");
        require(!collectionConfigs[collectionAddress].registered, "CATA: already registered");
        require(declaredMaxSupply >= 1, "CATA: declared >=1");

        uint256 fee = _calculateRegistrationFee(declaredMaxSupply);
        require(balanceOf(_msgSender()) >= fee, "CATA: insufficient bal");

        uint256 burnAmount = (fee * 90) / 100;
        _burn(_msgSender(), burnAmount);
        burnedCatalystByCollection[collectionAddress] += burnAmount;

        // update incremental topCollections (cheap)
        _updateTopCollectionsOnBurn(collectionAddress);

        uint256 treasuryAmount = fee - burnAmount;
        uint256 deployerShare = (treasuryAmount * deployerFeeShareRate) / 100;
        uint256 communityTreasuryShare = treasuryAmount - deployerShare;

        _transfer(_msgSender(), deployerAddress, deployerShare);
        _transfer(_msgSender(), treasuryAddress, communityTreasuryShare);

        // add to registeredCollections
        registeredCollections.push(collectionAddress);
        registeredIndex[collectionAddress] = registeredCollections.length; // 1-based index

        collectionConfigs[collectionAddress] = CollectionConfig({
            totalStaked: 0,
            totalStakers: 0,
            registered: true,
            declaredSupply: declaredMaxSupply
        });

        // if eligibleCount increased, rebuild topCollections (admin only operation but we do automatically here)
        _maybeRebuildTopCollections();

        emit CollectionAdded(collectionAddress, declaredMaxSupply, fee);
    }

    function removeCollection(address collectionAddress) external onlyRole(CONTRACT_ADMIN_ROLE) whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: not registered");

        collectionConfigs[collectionAddress].registered = false;

        // remove from registeredCollections array
        uint256 idx = registeredIndex[collectionAddress];
        if (idx != 0) {
            uint256 i = idx - 1;
            uint256 last = registeredCollections.length - 1;
            if (i != last) {
                address lastAddr = registeredCollections[last];
                registeredCollections[i] = lastAddr;
                registeredIndex[lastAddr] = i + 1;
            }
            registeredCollections.pop();
            registeredIndex[collectionAddress] = 0;
        }

        // also remove from topCollections if present
        for (uint256 t = 0; t < topCollections.length; t++) {
            if (topCollections[t] == collectionAddress) {
                for (uint256 j = t; j + 1 < topCollections.length; j++) {
                    topCollections[j] = topCollections[j + 1];
                }
                topCollections.pop();
                break;
            }
        }

        emit CollectionRemoved(collectionAddress);
    }

    // ---------- Governance: propose / vote / execute ----------
    function propose(
        ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collectionContext
    ) external whenNotPaused returns (bytes32) {
        bool eligible = false;

        // check if proposer stakes in any topCollections (full eligibility)
        for (uint256 i = 0; i < topCollections.length; i++) {
            address coll = topCollections[i];
            if (coll == address(0)) continue;
            if (stakePortfolioByUser[coll][_msgSender()].length > 0) {
                eligible = true;
                break;
            }
        }

        // fallback: proposer stakes in collectionContext that burned >= threshold
        if (!eligible && collectionContext != address(0)) {
            if (burnedCatalystByCollection[collectionContext] >= minBurnContributionForVote) {
                if (stakePortfolioByUser[collectionContext][_msgSender()].length > 0) {
                    eligible = true;
                }
            }
        }

        require(eligible, "CATA: proposer not eligible");

        bytes32 proposalId = keccak256(abi.encodePacked(uint256(pType), paramTarget, newValue, collectionContext, block.number, _msgSender()));
        Proposal storage p = proposals[proposalId];
        require(p.startBlock == 0, "CATA: proposal exists");

        p.pType = pType;
        p.paramTarget = paramTarget;
        p.newValue = newValue;
        p.collectionAddress = collectionContext;
        p.proposer = _msgSender();
        p.startBlock = block.number;
        p.endBlock = block.number + votingDurationBlocks;
        p.votesScaled = 0;
        p.executed = false;

        emit ProposalCreated(proposalId, pType, paramTarget, collectionContext, _msgSender(), newValue, p.startBlock, p.endBlock);
        return proposalId;
    }

    // Vote with weight attribution & per-collection cap, stake-age enforced
    function vote(bytes32 proposalId) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(p.startBlock != 0, "CATA: proposal not found");
        require(block.number >= p.startBlock && block.number <= p.endBlock, "CATA: voting closed");
        require(!p.executed, "CATA: already executed");
        require(!hasVoted[proposalId][_msgSender()], "CATA: already voted");

        uint256 weight = 0;
        address attributedCollection = address(0);

        // 1) full weight if voter stakes in any topCollections and meets stake-age in that collection
        for (uint256 i = 0; i < topCollections.length; i++) {
            address coll = topCollections[i];
            if (coll == address(0)) continue;
            uint256[] storage portfolio = stakePortfolioByUser[coll][_msgSender()];
            if (portfolio.length > 0) {
                // check if any token in portfolio has stakeBlock old enough
                bool hasOldStake = false;
                for (uint256 j = 0; j < portfolio.length; j++) {
                    uint256 tid = portfolio[j];
                    StakeInfo storage si = stakeLog[coll][_msgSender()][tid];
                    if (si.currentlyStaked && block.number >= si.stakeBlock + minStakeAgeForVoting) {
                        hasOldStake = true;
                        break;
                    }
                }
                if (hasOldStake) {
                    weight = WEIGHT_SCALE;
                    attributedCollection = coll;
                    break;
                }
            }
        }

        // 2) fractional weight if not topCollections voter: check proposal.collectionAddress
        if (weight == 0 && p.collectionAddress != address(0)) {
            uint256[] storage port = stakePortfolioByUser[p.collectionAddress][_msgSender()];
            if (port.length > 0 && burnedCatalystByCollection[p.collectionAddress] >= minBurnContributionForVote) {
                // check stake-age in that collection
                bool hasOld = false;
                for (uint256 k = 0; k < port.length; k++) {
                    uint256 tid2 = port[k];
                    StakeInfo storage si2 = stakeLog[p.collectionAddress][_msgSender()][tid2];
                    if (si2.currentlyStaked && block.number >= si2.stakeBlock + minStakeAgeForVoting) {
                        hasOld = true;
                        break;
                    }
                }
                if (hasOld) {
                    weight = smallCollectionVoteWeightScaled;
                    attributedCollection = p.collectionAddress;
                }
            }
        }

        require(weight > 0, "CATA: not eligible to vote (stake age or not in top)");

        // Enforce per-collection per-proposal cap:
        uint256 cap = (minVotesRequiredScaled * collectionVoteCapPercent) / 100;
        uint256 current = proposalCollectionVotesScaled[proposalId][attributedCollection];
        require(current + weight <= cap, "CATA: collection vote cap reached for proposal");

        // record
        hasVoted[proposalId][_msgSender()] = true;
        p.votesScaled += weight;
        proposalCollectionVotesScaled[proposalId][attributedCollection] = current + weight;

        emit VoteCast(proposalId, _msgSender(), weight, attributedCollection);
    }

    function executeProposal(bytes32 proposalId) external whenNotPaused nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.startBlock != 0, "CATA: proposal not found");
        require(block.number > p.endBlock, "CATA: voting window not ended");
        require(!p.executed, "CATA: already executed");
        require(p.votesScaled >= minVotesRequiredScaled, "CATA: insufficient votes");

        // apply change by type (same as prior contract)
        if (p.pType == ProposalType.BASE_REWARD) {
            uint256 old = baseRewardRate;
            uint256 newRate = p.newValue;
            if (maxBaseRewardRate != 0 && newRate > maxBaseRewardRate) {
                baseRewardRate = maxBaseRewardRate;
            } else {
                baseRewardRate = newRate;
            }
            emit BaseRewardRateUpdated(old, baseRewardRate);
            emit ProposalExecuted(proposalId, baseRewardRate);
        } else if (p.pType == ProposalType.HARVEST_FEE) {
            require(p.newValue <= 100, "CATA: harvest fee >100");
            uint256 old = initialHarvestBurnFeeRate;
            initialHarvestBurnFeeRate = p.newValue;
            emit HarvestFeeUpdated(old, p.newValue);
            emit ProposalExecuted(proposalId, p.newValue);
        } else if (p.pType == ProposalType.UNSTAKE_FEE) {
            uint256 old = unstakeBurnFee;
            unstakeBurnFee = p.newValue;
            emit UnstakeFeeUpdated(old, p.newValue);
            emit ProposalExecuted(proposalId, p.newValue);
        } else if (p.pType == ProposalType.REGISTRATION_FEE) {
            uint256 old = collectionRegistrationFee;
            collectionRegistrationFee = p.newValue;
            emit RegistrationFeeUpdated(old, p.newValue);
            emit ProposalExecuted(proposalId, p.newValue);
        } else if (p.pType == ProposalType.TREASURY_SPLIT) {
            require(p.newValue <= 100, "CATA: invalid deployer share");
            uint256 old = deployerFeeShareRate;
            deployerFeeShareRate = p.newValue;
            emit TreasurySplitUpdated(old, p.newValue);
            emit ProposalExecuted(proposalId, p.newValue);
        } else if (p.pType == ProposalType.VOTING_PARAM) {
            uint8 target = p.paramTarget;
            if (target == 0) {
                uint256 old = minVotesRequiredScaled;
                minVotesRequiredScaled = p.newValue;
                emit VotingParamUpdated(target, old, p.newValue);
            } else if (target == 1) {
                uint256 old = votingDurationBlocks;
                votingDurationBlocks = p.newValue;
                emit VotingParamUpdated(target, old, p.newValue);
            } else if (target == 2) {
                uint256 old = smallCollectionVoteWeightScaled;
                require(p.newValue <= WEIGHT_SCALE, "CATA: weight >1.0");
                smallCollectionVoteWeightScaled = p.newValue;
                emit VotingParamUpdated(target, old, p.newValue);
            } else if (target == 3) {
                uint256 old = minBurnContributionForVote;
                minBurnContributionForVote = p.newValue;
                emit VotingParamUpdated(target, old, p.newValue);
            } else if (target == 4) {
                uint256 old = maxBaseRewardRate;
                maxBaseRewardRate = p.newValue;
                emit VotingParamUpdated(target, old, p.newValue);
            } else if (target == 5) {
                uint256 old = numberOfBlocksPerRewardUnit;
                numberOfBlocksPerRewardUnit = p.newValue;
                emit VotingParamUpdated(target, old, p.newValue);
            } else {
                revert("CATA: unknown paramTarget");
            }
            emit ProposalExecuted(proposalId, p.newValue);
        } else {
            revert("CATA: unknown proposal type");
        }

        p.executed = true;
    }

    // ---------- Helpers: topCollections incremental updates ----------
    // Called frequently when burns increase for a collection to try to insert/reposition it in the topCollections list
    function _updateTopCollectionsOnBurn(address collection) internal {
        // if not registered, nothing
        if (!_isRegistered(collection)) return;

        uint256 burned = burnedCatalystByCollection[collection];
        uint256 ec = eligibleCount();
        if (ec == 0) ec = 1;

        // if topCollections empty, insert
        if (topCollections.length == 0) {
            topCollections.push(collection);
            return;
        }

        // if already present, remove it first (so we can re-insert)
        for (uint256 i = 0; i < topCollections.length; i++) {
            if (topCollections[i] == collection) {
                for (uint256 j = i; j + 1 < topCollections.length; j++) {
                    topCollections[j] = topCollections[j + 1];
                }
                topCollections.pop();
                break;
            }
        }

        // insert into sorted position
        bool inserted = false;
        for (uint256 i = 0; i < topCollections.length; i++) {
            if (burned > burnedCatalystByCollection[topCollections[i]]) {
                topCollections.push(topCollections[topCollections.length - 1]);
                for (uint256 j = topCollections.length - 1; j > i; j--) {
                    topCollections[j] = topCollections[j - 1];
                }
                topCollections[i] = collection;
                inserted = true;
                break;
            }
        }
        if (!inserted) {
            topCollections.push(collection);
        }

        // trim to eligibleCount
        uint256 maxLen = ec;
        while (topCollections.length > maxLen) {
            topCollections.pop();
        }
    }

    // Called when eligibleCount may have increased (new registration) to rebuild topCollections fully.
    // This performs a simple selection selection algorithm: repeatedly pick the max burned not yet selected.
    function _rebuildTopCollections() internal {
        uint256 total = registeredCollections.length;
        if (total == 0) {
            delete topCollections;
            return;
        }

        uint256 ec = eligibleCount();
        if (ec == 0) ec = 1;
        if (ec > total) ec = total;

        // temporary arrays in memory for selection
        address[] memory selected = new address[](ec);
        bool[] memory picked = new bool[](total);

        for (uint256 s = 0; s < ec; s++) {
            uint256 maxBurn = 0;
            uint256 maxIdx = 0;
            bool found = false;
            for (uint256 i = 0; i < total; i++) {
                if (picked[i]) continue;
                address cand = registeredCollections[i];
                uint256 b = burnedCatalystByCollection[cand];
                if (!found || b > maxBurn) {
                    maxBurn = b;
                    maxIdx = i;
                    found = true;
                }
            }
            if (found) {
                picked[maxIdx] = true;
                selected[s] = registeredCollections[maxIdx];
            }
        }

        // copy into topCollections
        delete topCollections;
        for (uint256 k = 0; k < ec; k++) {
            topCollections.push(selected[k]);
        }
    }

    // decide if rebuild is necessary and do it
    function _maybeRebuildTopCollections() internal {
        // if new eligibleCount > current topCollections length, rebuild to include next best
        uint256 ec = eligibleCount();
        if (ec == 0) ec = 1;
        if (ec > topCollections.length) {
            _rebuildTopCollections();
        } else {
            // if topCollections is empty but there are registeredCollections, rebuild
            if (topCollections.length == 0 && registeredCollections.length > 0) {
                _rebuildTopCollections();
            }
        }
    }

    // ---------- Admin setters & rescue ----------
    function setTopPercent(uint256 _percent) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_percent >= 1 && _percent <= 100, "CATA: percent 1..100");
        topPercent = _percent;
        // after changing topPercent rebuild to new eligibleCount
        _rebuildTopCollections();
    }

    function setCollectionVoteCapPercent(uint256 _p) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_p >= 1 && _p <= 100, "CATA: 1..100");
        collectionVoteCapPercent = _p;
    }

    function setMinStakeAgeForVoting(uint256 _blocks) external onlyRole(CONTRACT_ADMIN_ROLE) {
        minStakeAgeForVoting = _blocks;
    }

    function setMaxBaseRewardRate(uint256 _cap) external onlyRole(CONTRACT_ADMIN_ROLE) {
        maxBaseRewardRate = _cap;
    }

    function setWelcomeBonusBaseRate(uint256 _newRate) external onlyRole(CONTRACT_ADMIN_ROLE) {
        welcomeBonusBaseRate = _newRate;
    }

    function setWelcomeBonusIncrementPerNFT(uint256 _inc) external onlyRole(CONTRACT_ADMIN_ROLE) {
        welcomeBonusIncrementPerNFT = _inc;
    }

    function setHarvestRateAdjustmentFactor(uint256 _factor) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_factor > 0, "CATA: >0");
        harvestRateAdjustmentFactor = _factor;
    }

    function setTermDurationBlocks(uint256 _blocks) external onlyRole(CONTRACT_ADMIN_ROLE) {
        termDurationBlocks = _blocks;
    }

    function setStakingCooldownBlocks(uint256 _blocks) external onlyRole(CONTRACT_ADMIN_ROLE) {
        stakingCooldownBlocks = _blocks;
    }

    function setRegistrationFeeBrackets(
        uint256 _smallMin,
        uint256 _smallMax,
        uint256 _medMin,
        uint256 _medMax,
        uint256 _largeMin,
        uint256 _largeCap
    ) external onlyRole(CONTRACT_ADMIN_ROLE) {
        SMALL_MIN_FEE = _smallMin;
        SMALL_MAX_FEE = _smallMax;
        MED_MIN_FEE = _medMin;
        MED_MAX_FEE = _medMax;
        LARGE_MIN_FEE = _largeMin;
        LARGE_MAX_FEE_CAP = _largeCap;
    }

    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) {
        _pause();
        emit Paused(_msgSender());
    }

    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) {
        _unpause();
        emit Unpaused(_msgSender());
    }

    function addContractAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(CONTRACT_ADMIN_ROLE, admin);
        emit AdminAdded(admin);
    }

    function removeContractAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(CONTRACT_ADMIN_ROLE, admin);
        emit AdminRemoved(admin);
    }

    function emergencyWithdrawERC20(address token, address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(to != address(0), "CATA: invalid to");
        IERC20(token).transfer(to, amount);
        emit EmergencyWithdrawnERC20(token, to, amount);
    }

    function rescueERC721(address token, uint256 tokenId, address to) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(to != address(0), "CATA: invalid to");
        IERC721(token).safeTransferFrom(address(this), to, tokenId);
        emit RescuedERC721(token, tokenId, to);
    }

    // ---------- Helpers & math ----------
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
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

    // ---------- View getters ----------
    function getTopCollections() external view returns (address[] memory) {
        return topCollections;
    }

    function getRegisteredCollections() external view returns (address[] memory) {
        return registeredCollections;
    }

    function getProposal(bytes32 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function getBurnedCatalystByCollection(address collection) external view returns (uint256) {
        return burnedCatalystByCollection[collection];
    }

    // ---------- ERC721 Receiver ----------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
