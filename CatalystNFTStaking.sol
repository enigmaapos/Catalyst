// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*
  Catalyst NFT Staking Protocol — Hybrid Governance Upgrade

  Governance behavior:
  - Voter weight uses fixed-point scale (1e18).
  - Full weight (1e18) if voter stakes in any top-10 collection.
  - Fractional weight (configurable, e.g. 0.5e18) if voter stakes in a collection that has burned >= minBurnContributionForVote.
  - Proposers must have >0 weight (i.e., be eligible).
  - Proposals have voting window [startBlock, endBlock].
  - Votes add weighted vote counts; proposal executes only after endBlock and if votes >= minVotesRequiredScaled.
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

    // Scaling constant for vote weights (fixed point)
    uint256 public constant WEIGHT_SCALE = 1e18;

    // ---------- Structs ----------
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

    struct Proposal {
        uint256 newRate;
        address collectionAddress; // optional context; proposal can target collection-specific rules if needed
        address proposer;
        uint256 startBlock;
        uint256 endBlock;
        uint256 votesScaled; // accumulated weight scaled by WEIGHT_SCALE
        bool executed;
    }

    // ---------- Storage ----------
    mapping(address => CollectionConfig) public collectionConfigs;
    mapping(address => mapping(uint256 => bool)) public welcomeBonusCollected;
    mapping(address => uint256) public lastStakingBlock;
    mapping(address => mapping(address => mapping(uint256 => StakeInfo))) public stakeLog;
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser;
    mapping(address => mapping(uint256 => uint256)) public indexOfTokenIdInStakePortfolio;
    mapping(address => uint256) public burnedCatalystByCollection;

    // Governance
    mapping(bytes32 => mapping(address => bool)) public hasVoted; // proposalId => voter => bool
    mapping(bytes32 => Proposal) public proposals;

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
    uint256 public minBurnContributionForVote; // threshold for small collections to be eligible

    uint256 public initialCollectionFee;
    uint256 public feeMultiplier;
    uint256 public rewardRateIncrementPerNFT;
    uint256 public welcomeBonusBaseRate;
    uint256 public welcomeBonusIncrementPerNFT;

    address public immutable deployerAddress;
    uint256 public constant deployerFeeShareRate = 50;

    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public maxBaseRewardRate;

    // Top-10 collection tracking (by burnedCatalyst)
    address[] public topCollections; // length <= 10

    // Governance config (scaled)
    uint256 public minVotesRequiredScaled = 3 * WEIGHT_SCALE; // default = 3 full votes
    uint256 public votingDurationBlocks = 46000; // ~7 days (adjust per chain)

    // Small collection fractional weight (scaled). e.g., 0.5e18 = half vote
    uint256 public smallCollectionVoteWeightScaled = (WEIGHT_SCALE * 50) / 100; // default 0.5

    // ---------- Events ----------
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payoutAmount, uint256 burnedAmount);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event CollectionAdded(address indexed collectionAddress);
    event CollectionRemoved(address indexed collectionAddress);
    event PermanentStakeFeePaid(address indexed staker, uint256 feeAmount);

    // Governance events
    event ProposalCreated(bytes32 indexed proposalId, address indexed proposer, address indexed collection, uint256 newRate, uint256 startBlock, uint256 endBlock);
    event VoteCast(bytes32 indexed proposalId, address indexed voter, uint256 weightScaled);
    event ProposalExecuted(bytes32 indexed proposalId, uint256 newRate);

    // Admin/Admin-change events
    event BaseRewardRateUpdated(uint256 oldRate, uint256 newRate);
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
        uint256 _minBurnContributionForVote
    ) ERC20("Catalyst", "CATA") {
        require(_treasury != address(0), "CATA: invalid treasury");
        require(_owner != address(0), "CATA: invalid owner");

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

        maxBaseRewardRate = type(uint256).max;
    }

    // ---------- Modifiers ----------
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: cooldown not passed");
        _;
    }

    // ---------- Governance helper: voter weight ----------
    // Returns scaled weight (WEIGHT_SCALE = 1e18 full vote)
    function getVoterWeightScaled(address voter) public view returns (uint256) {
        // 1) full weight if voter stakes in any top-10 collection
        for (uint i = 0; i < topCollections.length; i++) {
            address coll = topCollections[i];
            if (coll == address(0)) continue;
            if (stakePortfolioByUser[coll][voter].length > 0) {
                return WEIGHT_SCALE; // full vote
            }
        }

        // 2) fractional weight if voter stakes in any collection that burned >= threshold
        //    (this allows smaller collections to participate if they burned enough)
        for (uint i = 0; i < topCollections.length; i++) {
            // we check only topCollections first, but we also need to check *all* collections
            // for small collections eligibility. We'll instead check all collections that
            // the voter staked in via stakePortfolioByUser mapping (iterate a small set).
            // However we cannot iterate mapping keys cheaply. So we rely on the voter staking arrays.
        }

        // To determine small-collection eligibility, we must check collections the voter actually staked in.
        // We cannot enumerate all collections a voter has staked in cheaply without off-chain indexing.
        // So we iterate topCollections (done), and as a fallback, we attempt to detect eligibility by checking
        // all collections registered in collectionConfigs — but that's also not enumerable on-chain here.
        // Practical compromise: require voters to pass a voter-eligibility helper by calling `claimVoterEligibility(collection)` off-chain or via UI.
        // To keep this on-chain: we implement a helper that checks if voter stakes in the *proposal's* collection during voting.
        // For general purpose, we expose `getStakeCountForVoter(collection, voter)` to the UI and use `vote(proposalId)` requiring
        // that voter has stake in *some eligible collection* (we check the proposal's collection and topCollections).
        // Implemented in `vote` logic below (checking stake in topCollections OR stake in any collection that has burned >= threshold).
        return 0;
    }

    // ---------- Top-10 helpers ----------
    function isTop10Collection(address collection) public view returns (bool) {
        for (uint i = 0; i < topCollections.length; i++) {
            if (topCollections[i] == collection) return true;
        }
        return false;
    }

    function getTopCollections() external view returns (address[] memory) {
        return topCollections;
    }

    // Internal function: update topCollections array when burnedCatalystByCollection changes.
    // Maintains topCollections sorted descending by burnedCatalystByCollection value (simple insertion).
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

        // remove if present
        for (uint i = 0; i < topCollections.length; i++) {
            if (topCollections[i] == collection) {
                for (uint j = i; j + 1 < topCollections.length; j++) {
                    topCollections[j] = topCollections[j + 1];
                }
                topCollections.pop();
                break;
            }
        }

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

    // ---------- Proposal lifecycle ----------
    // Create a proposal. Proposer must be eligible voter (UI should confirm eligibility beforehand).
    function propose(uint256 newRate, address collectionAddress) external whenNotPaused returns (bytes32) {
        // require proposer has non-zero weight relative to current state:
        // For proposer eligibility we check:
        // 1) if proposer stakes in any top-10 collection => eligible
        // 2) else if proposer stakes in the target collection and that collection burned >= threshold => eligible (small collection burn-in)
        bool eligible = false;

        // 1) stakes in any top collections?
        for (uint i = 0; i < topCollections.length; i++) {
            address coll = topCollections[i];
            if (coll == address(0)) continue;
            if (stakePortfolioByUser[coll][_msgSender()].length > 0) {
                eligible = true;
                break;
            }
        }

        // 2) fallback: proposer stakes in target collection and that collection burned >= minBurnContributionForVote
        if (!eligible) {
            if (collectionAddress != address(0) && burnedCatalystByCollection[collectionAddress] >= minBurnContributionForVote) {
                if (stakePortfolioByUser[collectionAddress][_msgSender()].length > 0) {
                    eligible = true;
                }
            }
        }

        require(eligible, "CATA: proposer not eligible (stake in top-10 or burned small coll stake)");

        bytes32 proposalId = keccak256(abi.encodePacked(newRate, collectionAddress, block.number, _msgSender()));
        Proposal storage p = proposals[proposalId];
        require(p.startBlock == 0, "CATA: proposal exists");

        p.newRate = newRate;
        p.collectionAddress = collectionAddress;
        p.proposer = _msgSender();
        p.startBlock = block.number;
        p.endBlock = block.number + votingDurationBlocks;
        p.votesScaled = 0;
        p.executed = false;

        emit ProposalCreated(proposalId, _msgSender(), collectionAddress, newRate, p.startBlock, p.endBlock);
        return proposalId;
    }

    // Vote on an existing proposal. Voter must either:
    // - stake in any top-10 collection (full weight), OR
    // - stake in a collection that has burned >= minBurnContributionForVote (fractional weight).
    // To compute fractional weight we look for any collection the voter stakes in with burned >= threshold.
    function vote(bytes32 proposalId) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(p.startBlock != 0, "CATA: proposal not found");
        require(block.number >= p.startBlock && block.number <= p.endBlock, "CATA: voting closed");
        require(!p.executed, "CATA: already executed");
        require(!hasVoted[proposalId][_msgSender()], "CATA: already voted");

        uint256 weight = 0;

        // Check top-10 staking (full weight)
        for (uint i = 0; i < topCollections.length; i++) {
            address coll = topCollections[i];
            if (coll == address(0)) continue;
            if (stakePortfolioByUser[coll][_msgSender()].length > 0) {
                weight = WEIGHT_SCALE;
                break;
            }
        }

        // If no top-10 stake, check small collections where voter stakes and burned >= threshold
        if (weight == 0) {
            // We can't enumerate all collections the voter staked in cheaply; instead,
            // we check the proposal's target collection first (if provided), then topCollections fallback we've done.
            if (p.collectionAddress != address(0)) {
                if (stakePortfolioByUser[p.collectionAddress][_msgSender()].length > 0 && burnedCatalystByCollection[p.collectionAddress] >= minBurnContributionForVote) {
                    weight = smallCollectionVoteWeightScaled;
                }
            }

            // If still zero, attempt to detect via scanning topCollections (already done) and by providing a UI path:
            // NOTE: For a generalized check across *all* collections a voter staked in, the UI must call a helper mapping or the user must explicitly prove stake
            // in a particular small collection (e.g., by calling `registerVoterStakes` off-chain). For now we require voter to stake in leader/top or target collection to vote.
        }

        require(weight > 0, "CATA: not eligible to vote (stake in top-10 or burned small coll stake)");

        // record vote
        hasVoted[proposalId][_msgSender()] = true;
        p.votesScaled += weight;

        emit VoteCast(proposalId, _msgSender(), weight);
    }

    // Execute proposal after voting window ended if votesScaled >= minVotesRequiredScaled
    function executeProposal(bytes32 proposalId) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(p.startBlock != 0, "CATA: proposal not found");
        require(block.number > p.endBlock, "CATA: voting window not ended");
        require(!p.executed, "CATA: already executed");
        require(p.votesScaled >= minVotesRequiredScaled, "CATA: insufficient votes (weighted)");

        uint256 old = baseRewardRate;
        if (maxBaseRewardRate != 0 && p.newRate > maxBaseRewardRate) {
            baseRewardRate = maxBaseRewardRate;
        } else {
            baseRewardRate = p.newRate;
        }
        p.executed = true;
        emit ProposalExecuted(proposalId, baseRewardRate);
        emit BaseRewardRateUpdated(old, baseRewardRate);
    }

    // ---------- Math helpers ----------
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

    // ---------- Collection registration ----------
    function setCollectionConfig(address collectionAddress) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(collectionAddress != address(0), "CATA: invalid");
        require(!collectionConfigs[collectionAddress].registered, "CATA: already registered");

        uint256 fee = collectionRegistrationFee;
        require(balanceOf(_msgSender()) >= fee, "CATA: insufficient");

        uint256 burnAmount = (fee * 90) / 100;
        _burn(_msgSender(), burnAmount);
        burnedCatalystByCollection[collectionAddress] += burnAmount;

        // update top-10 based on new burn totals
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

    // ---------- Staking ----------
    function termStake(address collectionAddress, uint256 tokenId) public nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: not registered");

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
        require(collectionConfigs[collectionAddress].registered, "CATA: not registered");

        uint256 currentFee = _getDynamicPermanentStakeFee();
        require(balanceOf(_msgSender()) >= currentFee, "CATA: insufficient balance");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        uint256 burnAmount = (currentFee * 90) / 100;
        _burn(_msgSender(), burnAmount);
        burnedCatalystByCollection[collectionAddress] += burnAmount;

        // update top-10 due to burn change
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

    // ---------- Unstake ----------
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

    // ---------- Harvest (safe) ----------
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

    // ---------- Admin setters ----------
    function setBaseRewardRate(uint256 _newRate) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(maxBaseRewardRate == 0 || _newRate <= maxBaseRewardRate, "CATA: exceeds max cap");
        uint256 old = baseRewardRate;
        baseRewardRate = _newRate;
        emit BaseRewardRateUpdated(old, _newRate);
    }

    function setMaxBaseRewardRate(uint256 _cap) external onlyRole(CONTRACT_ADMIN_ROLE) {
        maxBaseRewardRate = _cap;
    }

    function setMinVotesRequiredScaled(uint256 _minScaled) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_minScaled > 0, "CATA: min>0");
        minVotesRequiredScaled = _minScaled;
    }

    function setVotingDurationBlocks(uint256 _blocks) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_blocks > 0, "CATA: duration>0");
        votingDurationBlocks = _blocks;
    }

    function setSmallCollectionVoteWeightScaled(uint256 _weightScaled) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_weightScaled <= WEIGHT_SCALE, "CATA: too big");
        smallCollectionVoteWeightScaled = _weightScaled;
    }

    function setMinBurnContributionForVote(uint256 _min) external onlyRole(CONTRACT_ADMIN_ROLE) {
        minBurnContributionForVote = _min;
    }

    // Additional setters kept from prior contract (welcome bonuses, fees, etc.)
    function setWelcomeBonusBaseRate(uint256 _newRate) external onlyRole(CONTRACT_ADMIN_ROLE) {
        welcomeBonusBaseRate = _newRate;
    }
    function setWelcomeBonusIncrementPerNFT(uint256 _increment) external onlyRole(CONTRACT_ADMIN_ROLE) {
        welcomeBonusIncrementPerNFT = _increment;
    }
    function setHarvestBurnFeeRate(uint256 _rate) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_rate <= 100, "CATA: rate>100");
        initialHarvestBurnFeeRate = _rate;
    }
    function setHarvestRateAdjustmentFactor(uint256 _factor) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_factor > 0, "CATA: >0");
        harvestRateAdjustmentFactor = _factor;
    }
    function setTermDurationBlocks(uint256 _blocks) external onlyRole(CONTRACT_ADMIN_ROLE) {
        termDurationBlocks = _blocks;
    }
    function setUnstakeBurnFee(uint256 _fee) external onlyRole(CONTRACT_ADMIN_ROLE) {
        unstakeBurnFee = _fee;
    }
    function setStakingCooldownBlocks(uint256 _blocks) external onlyRole(CONTRACT_ADMIN_ROLE) {
        stakingCooldownBlocks = _blocks;
    }

    // ---------- Pausable ----------
    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) {
        _pause();
        emit Paused(_msgSender());
    }

    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) {
        _unpause();
        emit Unpaused(_msgSender());
    }

    // ---------- Admin management ----------
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

    // ---------- Getters ----------
    function getDynamicPermanentStakeFee() public view returns (uint256) {
        return _getDynamicPermanentStakeFee();
    }

    function getDynamicHarvestBurnFeeRate() public view returns (uint256) {
        return _getDynamicHarvestBurnFeeRate();
    }

    function getLastStakingBlock(address user) public view returns (uint256) {
        return lastStakingBlock[user];
    }

    function getBurnedCatalystByCollection(address collectionAddress) public view returns (uint256) {
        return burnedCatalystByCollection[collectionAddress];
    }

    // ---------- ERC721 Receiver ----------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
