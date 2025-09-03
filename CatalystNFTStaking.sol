// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*
  Catalyst NFT Staking Protocol — Multi-Parameter Governance Edition

  Key features included:
  - ERC20 CATA token (mint/burn integrated for rewards and fees).
  - NFT staking (term and permanent), welcome bonus, harvest, unstake burn fee.
  - Safe harvest: mint then burn user's burn portion.
  - Collection registration (admin-only) with 90% burn / 10% treasury+deployer split.
  - Top-10 collections tracked by burned CATA (updated on burns).
  - Hybrid governance:
      * Top-10 stakers = full vote weight (1e18)
      * Small collections can become eligible by burning >= minBurnContributionForVote and provide fractional weight (configurable)
      * Proposal types allow changing many protocol parameters:
          - BASE_REWARD, HARVEST_FEE, UNSTAKE_FEE, REGISTRATION_FEE, TREASURY_SPLIT,
            VOTING_PARAM (sub-targets encoded by paramTarget)
      * Proposals have voting window and require weighted votes >= minVotesRequiredScaled to pass
      * Execution only allowed after voting window ends (explicit executeProposal)
  - Admin controls: pausable, rescue, add/remove admins, set caps
  - Events for transparency
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

    // ---------- Constants ----------
    uint256 public constant WEIGHT_SCALE = 1e18; // scaled fixed-point 1.0
    uint256 public constant MAX_HARVEST_BATCH = 50;

    // ---------- Proposal / Governance Types ----------
    enum ProposalType {
        BASE_REWARD,       // set baseRewardRate
        HARVEST_FEE,       // set initialHarvestBurnFeeRate (%)
        UNSTAKE_FEE,       // set unstakeBurnFee (CATA)
        REGISTRATION_FEE,  // set collectionRegistrationFee (CATA)
        TREASURY_SPLIT,    // set deployerFeeShareRate (0..100)
        VOTING_PARAM       // sub-target encoded in paramTarget (see below)
    }

    // paramTarget codes for ProposalType.VOTING_PARAM
    // 0 => minVotesRequiredScaled
    // 1 => votingDurationBlocks
    // 2 => smallCollectionVoteWeightScaled
    // 3 => minBurnContributionForVote
    // 4 => maxBaseRewardRate
    // 5 => numberOfBlocksPerRewardUnit
    // (extendable)
    
    struct Proposal {
        ProposalType pType;
        uint8 paramTarget;      // used when pType == VOTING_PARAM
        uint256 newValue;       // numeric new value (units depend on pType)
        address collectionAddress; // optional context; used for small-collection proposals
        address proposer;
        uint256 startBlock;
        uint256 endBlock;
        uint256 votesScaled;    // accumulated weight scaled (WEIGHT_SCALE)
        bool executed;
    }

    // ---------- Storage: staking & collections ----------
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

    mapping(address => CollectionConfig) public collectionConfigs;
    mapping(address => mapping(uint256 => bool)) public welcomeBonusCollected;
    mapping(address => uint256) public lastStakingBlock;
    mapping(address => mapping(address => mapping(uint256 => StakeInfo))) public stakeLog;
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser;
    mapping(address => mapping(uint256 => uint256)) public indexOfTokenIdInStakePortfolio;

    // burned CATA per collection (used for top-10)
    mapping(address => uint256) public burnedCatalystByCollection;

    // proposals
    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public hasVoted; // proposalId => voter => bool

    // ---------- Tokenomics & params ----------
    uint256 public numberOfBlocksPerRewardUnit;
    uint256 public collectionRegistrationFee;
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
    uint256 public deployerFeeShareRate; // 0..100 (percent) — stored mutable via governance

    // governance controls
    address[] public topCollections; // <=10, sorted descending by burnedCatalystByCollection
    uint256 public minVotesRequiredScaled; // scaled by WEIGHT_SCALE
    uint256 public votingDurationBlocks;
    uint256 public smallCollectionVoteWeightScaled; // fractional weight for burned small collections
    uint256 public maxBaseRewardRate; // optional cap

    // ---------- Events ----------
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payoutAmount, uint256 burnedAmount);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event CollectionAdded(address indexed collectionAddress);
    event CollectionRemoved(address indexed collectionAddress);
    event PermanentStakeFeePaid(address indexed staker, uint256 feeAmount);

    event ProposalCreated(bytes32 indexed proposalId, ProposalType pType, uint8 paramTarget, address indexed collection, address indexed proposer, uint256 newValue, uint256 startBlock, uint256 endBlock);
    event VoteCast(bytes32 indexed proposalId, address indexed voter, uint256 weightScaled);
    event ProposalExecuted(bytes32 indexed proposalId, uint256 newValue);

    event BaseRewardRateUpdated(uint256 oldRate, uint256 newRate);
    event HarvestFeeUpdated(uint256 oldRate, uint256 newRate);
    event UnstakeFeeUpdated(uint256 oldFee, uint256 newFee);
    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasurySplitUpdated(uint256 oldShare, uint256 newShare);
    event VotingParamUpdated(uint8 paramTarget, uint256 oldValue, uint256 newValue);

    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event EmergencyWithdrawnERC20(address token, address to, uint256 amount);
    event RescuedERC721(address token, uint256 tokenId, address to);

    // ---------- Constructor ----------
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
        uint256 _collectionRegistrationFee,
        uint256 _unstakeBurnFee,
        uint256 _stakingCooldownBlocks,
        uint256 _harvestRateAdjustmentFactor,
        uint256 _minBurnContributionForVote,
        uint256 _initialDeployerSharePercent // 0..100
    ) ERC20("Catalyst", "CATA") {
        require(_treasury != address(0), "CATA: invalid treasury");
        require(_owner != address(0), "CATA: invalid owner");
        require(_initialDeployerSharePercent <= 100, "CATA: deployer share >100");

        // initial supply allocation to owner (example)
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

        collectionRegistrationFee = _collectionRegistrationFee;
        unstakeBurnFee = _unstakeBurnFee;
        initialHarvestBurnFeeRate = _initialHarvestBurnFeeRate;
        harvestRateAdjustmentFactor = _harvestRateAdjustmentFactor;
        minBurnContributionForVote = _minBurnContributionForVote;
        baseRewardRate = 0;

        deployerFeeShareRate = _initialDeployerSharePercent; // e.g., 50

        // governance defaults
        minVotesRequiredScaled = 3 * WEIGHT_SCALE; // default require 3 full votes
        votingDurationBlocks = 46000; // ~7 days (adjust per chain)
        smallCollectionVoteWeightScaled = (WEIGHT_SCALE * 50) / 100; // default 0.5
        maxBaseRewardRate = type(uint256).max;
    }

    // ---------- Modifiers ----------
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: cooldown not passed");
        _;
    }

    // ---------- --- Core functions: staking / harvest / unstake --- ----------
    function termStake(address collectionAddress, uint256 tokenId) public nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: collection not registered");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

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
        require(collectionConfigs[collectionAddress].registered, "CATA: collection not registered");

        uint256 currentFee = _getDynamicPermanentStakeFee();
        require(balanceOf(_msgSender()) >= currentFee, "CATA: insufficient CATA for fee");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        uint256 burnAmount = (currentFee * 90) / 100;
        _burn(_msgSender(), burnAmount);
        burnedCatalystByCollection[collectionAddress] += burnAmount;

        // update top-10 due to burn
        _updateTopCollections(collectionAddress);

        uint256 treasuryAmount = currentFee - burnAmount;
        uint256 deployerShare = (treasuryAmount * deployerFeeShareRate) / 100;
        uint256 communityTreasuryShare = treasuryAmount - deployerShare;

        _transfer(_msgSender(), deployerAddress, deployerShare);
        _transfer(_msgSender(), treasuryAddress, communityTreasuryShare);

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
        require(info.currentlyStaked, "CATA: token not staked");

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

    // ---------- Harvest (safe) ----------
    function _harvest(address collectionAddress, address user, uint256 tokenId) internal {
        StakeInfo storage info = stakeLog[collectionAddress][user][tokenId];
        uint256 rewardAmount = pendingRewards(collectionAddress, user, tokenId);

        if (rewardAmount > 0) {
            uint256 dynamicHarvestBurnFeeRate = _getDynamicHarvestBurnFeeRate();
            uint256 burnAmount = (rewardAmount * dynamicHarvestBurnFeeRate) / 100;
            uint256 payoutAmount = rewardAmount - burnAmount;

            // mint full reward then burn from user
            _mint(user, rewardAmount);

            if (burnAmount > 0) {
                _burn(user, burnAmount);
                burnedCatalystByCollection[collectionAddress] += burnAmount;

                // update top-10 since burn totals changed
                _updateTopCollections(collectionAddress);
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

    // ---------- Collection registration (admin-only) ----------
    function setCollectionConfig(address collectionAddress) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(collectionAddress != address(0), "CATA: invalid address");
        require(!collectionConfigs[collectionAddress].registered, "CATA: already registered");

        uint256 fee = collectionRegistrationFee;
        require(balanceOf(_msgSender()) >= fee, "CATA: insufficient balance");

        uint256 burnAmount = (fee * 90) / 100;
        _burn(_msgSender(), burnAmount);
        burnedCatalystByCollection[collectionAddress] += burnAmount;

        // update top-10
        _updateTopCollections(collectionAddress);

        uint256 treasuryAmount = fee - burnAmount;
        uint256 deployerShare = (treasuryAmount * deployerFeeShareRate) / 100;
        uint256 communityTreasuryShare = treasuryAmount - deployerShare;

        _transfer(_msgSender(), deployerAddress, deployerShare);
        _transfer(_msgSender(), treasuryAddress, communityTreasuryShare);

        collectionConfigs[collectionAddress] = CollectionConfig({ totalStaked: 0, totalStakers: 0, registered: true });

        emit CollectionAdded(collectionAddress);
    }

    function removeCollection(address collectionAddress) external onlyRole(CONTRACT_ADMIN_ROLE) whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: not registered");
        collectionConfigs[collectionAddress].registered = false;
        emit CollectionRemoved(collectionAddress);
    }

    // ---------- Governance: propose / vote / execute ----------
    // Propose a change: specify type, paramTarget (if needed), newValue, and optional collection context.
    function propose(
        ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collectionContext
    ) external whenNotPaused returns (bytes32) {
        // proposer eligibility: must be an active staker in a top-10 collection OR
        // be an active staker in collectionContext that has burned >= minBurnContributionForVote
        bool eligible = false;

        // 1) stake in any top collection?
        for (uint i = 0; i < topCollections.length; i++) {
            address coll = topCollections[i];
            if (coll == address(0)) continue;
            if (stakePortfolioByUser[coll][_msgSender()].length > 0) {
                eligible = true;
                break;
            }
        }

        // 2) fallback: stake in collectionContext AND that collection burned >= threshold
        if (!eligible && collectionContext != address(0)) {
            if (burnedCatalystByCollection[collectionContext] >= minBurnContributionForVote) {
                if (stakePortfolioByUser[collectionContext][_msgSender()].length > 0) {
                    eligible = true;
                }
            }
        }

        require(eligible, "CATA: proposer not eligible");

        // create proposal id deterministic-ish
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

    // Vote on a proposal. Weighted by:
    // - full weight (WEIGHT_SCALE) if voter stakes in any top-10 collection
    // - smallCollectionVoteWeightScaled if voter stakes in the proposal's collection and that collection burned >= threshold
    function vote(bytes32 proposalId) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(p.startBlock != 0, "CATA: proposal not found");
        require(block.number >= p.startBlock && block.number <= p.endBlock, "CATA: voting closed");
        require(!p.executed, "CATA: already executed");
        require(!hasVoted[proposalId][_msgSender()], "CATA: already voted");

        uint256 weight = 0;

        // check top-10 staking for full weight
        for (uint i = 0; i < topCollections.length; i++) {
            address coll = topCollections[i];
            if (coll == address(0)) continue;
            if (stakePortfolioByUser[coll][_msgSender()].length > 0) {
                weight = WEIGHT_SCALE;
                break;
            }
        }

        // if no top-10 stake, check proposal.collectionAddress eligibility for small collections
        if (weight == 0 && p.collectionAddress != address(0)) {
            if (stakePortfolioByUser[p.collectionAddress][_msgSender()].length > 0) {
                if (burnedCatalystByCollection[p.collectionAddress] >= minBurnContributionForVote) {
                    weight = smallCollectionVoteWeightScaled;
                }
            }
        }

        require(weight > 0, "CATA: not eligible to vote");

        hasVoted[proposalId][_msgSender()] = true;
        p.votesScaled += weight;

        emit VoteCast(proposalId, _msgSender(), weight);
    }

    // Execute a proposal after voting window ended and votesScaled >= minVotesRequiredScaled
    function executeProposal(bytes32 proposalId) external whenNotPaused nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.startBlock != 0, "CATA: proposal not found");
        require(block.number > p.endBlock, "CATA: voting window not ended");
        require(!p.executed, "CATA: already executed");
        require(p.votesScaled >= minVotesRequiredScaled, "CATA: insufficient votes");

        // Apply based on proposal type
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
            // use paramTarget to decide which voting parameter to update
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

    // ---------- Internal helpers & math ----------
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

    // ---------- Top-10 maintenance ----------
    function getTopCollections() external view returns (address[] memory) {
        return topCollections;
    }

    // Maintains topCollections as descending by burnedCatalystByCollection and length <= 10
    function _updateTopCollections(address collection) internal {
        uint256 burned = burnedCatalystByCollection[collection];
        if (burned == 0) {
            // remove if present
            for (uint i = 0; i < topCollections.length; i++) {
                if (topCollections[i] == collection) {
                    for (uint j = i; j + 1 < topCollections.length; j++) {
                        topCollections[j] = topCollections[j + 1];
                    }
                    topCollections.pop();
                    return;
                }
            }
            return;
        }

        // remove existing mention
        for (uint i = 0; i < topCollections.length; i++) {
            if (topCollections[i] == collection) {
                for (uint j = i; j + 1 < topCollections.length; j++) {
                    topCollections[j] = topCollections[j + 1];
                }
                topCollections.pop();
                break;
            }
        }

        // insert sorted
        bool inserted = false;
        for (uint i = 0; i < topCollections.length; i++) {
            if (burned > burnedCatalystByCollection[topCollections[i]]) {
                topCollections.push(topCollections[topCollections.length - 1]);
                for (uint j = topCollections.length - 1; j > i; j--) {
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

        if (topCollections.length > 10) {
            topCollections.pop();
        }
    }

    // ---------- Admin setters (non-governance, admin-only) ----------
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

    // ---------- Pausable & admin management ----------
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

    // ---------- Rescue utilities ----------
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

    // ---------- Getters for governance info ----------
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
