// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title Catalyst NFT Staking Protocol (Hardened)
 * @author Var (updated)
 *
 * Key fixes:
 * - Safe harvest: mint full reward to user, then burn user's burn portion (prevents _burn from contract).
 * - Admin-only setters: critical setters now require CONTRACT_ADMIN_ROLE.
 * - Added events for key parameter changes and governance actions.
 * - Added harvestBatch with batch size limit to avoid out-of-gas.
 * - Added removeCollection (admin).
 * - Improved pendingRewards math to reduce rounding/truncation problems.
 *
 * Note: This is still a core protocol contract — deploy admin keys behind multisig and add timelock for upgrades.
 */
contract CatalystNFTStaking is ERC20, AccessControl, IERC721Receiver, ReentrancyGuard {
    // Roles
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // A struct to hold the configuration for each NFT collection.
    struct CollectionConfig {
        uint256 totalStaked;
        uint256 totalStakers;
        bool registered;
    }

    // collection address => config
    mapping(address => CollectionConfig) public collectionConfigs;

    // Tracks if the welcome bonus has been collected for a given NFT.
    mapping(address => mapping(uint256 => bool)) public welcomeBonusCollected;

    // Tracks the last block a user performed a staking action.
    mapping(address => uint256) public lastStakingBlock;

    // Staking info per token
    struct StakeInfo {
        uint256 lastHarvestBlock;
        bool currentlyStaked;
        bool isPermanent; // True for permanent stake, False for term stake
        uint256 unstakeDeadlineBlock; // Block number when a term stake can be unstaked
    }

    // collectionAddress => owner => tokenId => StakeInfo
    mapping(address => mapping(address => mapping(uint256 => StakeInfo))) public stakeLog;

    // collectionAddress => owner => list of tokenIds
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser;

    // collectionAddress => tokenId => indexInStakePortfolio
    mapping(address => mapping(uint256 => uint256)) public indexOfTokenIdInStakePortfolio;

    // Tracks the total amount of CATA burned per collection. Used for governance.
    mapping(address => uint256) public burnedCatalystByCollection;

    // Simple multi-signature style voting for proposals.
    mapping(bytes32 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => uint256) public votesForProposal;

    // Parameters
    uint256 public numberOfBlocksPerRewardUnit;
    uint256 public collectionRegistrationFee; // Fee for the collection owner to register a collection (in CATA)
    uint256 public unstakeBurnFee;            // Fixed fee for unstaking (in CATA)
    address public treasuryAddress;           // Address where fees are sent
    uint256 public totalStakedNFTsCount;      // Tracks total NFTs across all collections
    uint256 public baseRewardRate;            // Measured in "wei-per-unitPeriod" (interpretation must be documented)
    uint256 public initialHarvestBurnFeeRate; // Initial rate (percentage) for the harvest burn fee
    uint256 public termDurationBlocks;        // Duration of a term stake in blocks
    uint256 public stakingCooldownBlocks;     // Cooldown period to prevent bot spamming
    uint256 public harvestRateAdjustmentFactor; // Used for dynamic harvest burn rate calculation
    uint256 public minBurnContributionForVote;  // Minimum burn to be a voter

    // Dynamic calculation values
    uint256 public initialCollectionFee;
    uint256 public feeMultiplier;
    uint256 public rewardRateIncrementPerNFT;
    uint256 public welcomeBonusBaseRate;
    uint256 public welcomeBonusIncrementPerNFT;

    // Creator's fee allocation (immutable receiver)
    address public immutable deployerAddress;
    uint256 public constant deployerFeeShareRate = 50; // 50% of the 10% fee goes to the deployer.

    // Batch limits
    uint256 public constant MAX_HARVEST_BATCH = 50;

    // Events
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payoutAmount, uint256 burnedAmount);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event CollectionAdded(address indexed collectionAddress);
    event CollectionRemoved(address indexed collectionAddress);
    event PermanentStakeFeePaid(address indexed staker, uint256 feeAmount);

    // Setter events
    event BaseRewardRateUpdated(uint256 oldRate, uint256 newRate);
    event WelcomeBonusBaseRateUpdated(uint256 oldRate, uint256 newRate);
    event WelcomeBonusIncrementUpdated(uint256 oldInc, uint256 newInc);
    event HarvestBurnFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event HarvestRateAdjustmentFactorUpdated(uint256 oldFactor, uint256 newFactor);
    event TermDurationBlocksUpdated(uint256 oldBlocks, uint256 newBlocks);
    event UnstakeBurnFeeUpdated(uint256 oldFee, uint256 newFee);
    event StakingCooldownBlocksUpdated(uint256 oldBlocks, uint256 newBlocks);
    event MinBurnContributionForVoteUpdated(uint256 oldMin, uint256 newMin);

    // Governance events
    event ProposalVoted(bytes32 indexed proposalId, address indexed voter);
    event ProposalExecuted(bytes32 indexed proposalId, uint256 newRate);

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
        require(_treasury != address(0), "CATA: Invalid treasury address");
        require(_owner != address(0), "CATA: Invalid owner");
        _mint(_owner, 25_185_000 * 10 ** 18);
        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        _setupRole(CONTRACT_ADMIN_ROLE, _owner);

        numberOfBlocksPerRewardUnit = 18782; // approx 1 day on Polygon
        treasuryAddress = _treasury;
        deployerAddress = _owner;

        // Set initial dynamic parameters
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
    }

    // ---------------------- Modifiers ----------------------
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: Staking cooldown period has not passed");
        _;
    }

    modifier onlyAuthorizedVoter(address collectionAddress) {
        require(burnedCatalystByCollection[collectionAddress] >= minBurnContributionForVote, "CATA: Caller's collection is not an authorized voter");
        _;
    }

    // ---------------------- Governance ----------------------
    function proposeAndVote(uint256 newRate, address collectionAddress) external onlyAuthorizedVoter(collectionAddress) {
        bytes32 proposalId = keccak256(abi.encodePacked("proposeBaseRewardRate", newRate));
        require(!hasVoted[proposalId][_msgSender()], "CATA: You have already voted on this proposal");

        hasVoted[proposalId][_msgSender()] = true;
        votesForProposal[proposalId] += 1;

        emit ProposalVoted(proposalId, _msgSender());

        // Require 2 votes from authorized voters to pass the proposal (example multisig-like quorum)
        if (votesForProposal[proposalId] >= 2) {
            uint256 oldRate = baseRewardRate;
            baseRewardRate = newRate;
            emit ProposalExecuted(proposalId, newRate);
            emit BaseRewardRateUpdated(oldRate, newRate);
            delete votesForProposal[proposalId]; // Reset for next proposal
        }
    }

    // ---------------------- Math ----------------------
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
        if (harvestRateAdjustmentFactor == 0) {
            return initialHarvestBurnFeeRate;
        }
        uint256 rate = initialHarvestBurnFeeRate + (baseRewardRate / harvestRateAdjustmentFactor);
        if (rate > 90) {
            return 90;
        }
        return rate;
    }

    // ---------------------- Collection Registration (admin allowlist) ----------------------
    function setCollectionConfig(address collectionAddress) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant {
        require(collectionAddress != address(0), "CATA: Invalid address");
        require(!collectionConfigs[collectionAddress].registered, "CATA: Collection already registered");

        uint256 fee = collectionRegistrationFee;
        require(balanceOf(_msgSender()) >= fee, "CATA: Insufficient CATA balance to pay collection registration fee");

        uint256 burnAmount = (fee * 90) / 100;
        _burn(_msgSender(), burnAmount);

        burnedCatalystByCollection[collectionAddress] += burnAmount;

        uint256 treasuryAmount = fee - burnAmount;
        uint256 deployerShare = (treasuryAmount * deployerFeeShareRate) / 100;
        uint256 communityTreasuryShare = treasuryAmount - deployerShare;

        _transfer(_msgSender(), deployerAddress, deployerShare);
        _transfer(_msgSender(), treasuryAddress, communityTreasuryShare);

        collectionConfigs[collectionAddress] = CollectionConfig({
            totalStaked: 0,
            totalStakers: 0,
            registered: true
        });

        emit CollectionAdded(collectionAddress);
    }

    // Allow admin to remove/delist a collection (on-chain flag)
    function removeCollection(address collectionAddress) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(collectionConfigs[collectionAddress].registered, "CATA: Not registered");
        collectionConfigs[collectionAddress].registered = false;
        emit CollectionRemoved(collectionAddress);
    }

    // ---------------------- Staking ----------------------
    function termStake(address collectionAddress, uint256 tokenId) public nonReentrant notInCooldown {
        require(collectionConfigs[collectionAddress].registered, "CATA: Collection not registered");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: Token is already staked");

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
        uint256 indexOfNewElement = stakePortfolioByUser[collectionAddress][_msgSender()].length - 1;
        indexOfTokenIdInStakePortfolio[collectionAddress][tokenId] = indexOfNewElement;

        if (!welcomeBonusCollected[collectionAddress][tokenId]) {
            uint256 dynamicWelcomeBonus = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
            _mint(_msgSender(), dynamicWelcomeBonus);
            welcomeBonusCollected[collectionAddress][tokenId] = true;
        }

        lastStakingBlock[_msgSender()] = block.number;

        emit NFTStaked(_msgSender(), collectionAddress, tokenId);
    }

    function permanentStake(address collectionAddress, uint256 tokenId) public nonReentrant notInCooldown {
        require(collectionConfigs[collectionAddress].registered, "CATA: Collection not registered");

        uint256 currentFee = _getDynamicPermanentStakeFee();
        require(balanceOf(_msgSender()) >= currentFee, "CATA: Insufficient CATA balance to pay fee");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: Token is already staked");

        uint256 burnAmount = (currentFee * 90) / 100;
        _burn(_msgSender(), burnAmount);
        burnedCatalystByCollection[collectionAddress] += burnAmount;

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
        uint256 indexOfNewElement = stakePortfolioByUser[collectionAddress][_msgSender()].length - 1;
        indexOfTokenIdInStakePortfolio[collectionAddress][tokenId] = indexOfNewElement;

        if (!welcomeBonusCollected[collectionAddress][tokenId]) {
            uint256 dynamicWelcomeBonus = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
            _mint(_msgSender(), dynamicWelcomeBonus);
            welcomeBonusCollected[collectionAddress][tokenId] = true;
        }

        lastStakingBlock[_msgSender()] = block.number;

        emit PermanentStakeFeePaid(_msgSender(), currentFee);
        emit NFTStaked(_msgSender(), collectionAddress, tokenId);
    }

    // ---------------------- Unstake ----------------------
    function unstake(address collectionAddress, uint256 tokenId) public nonReentrant {
        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(info.currentlyStaked, "CATA: Token is not staked");

        if (!info.isPermanent) {
            require(block.number >= info.unstakeDeadlineBlock, "CATA: Term stake has not expired yet");
        }

        // First, harvest pending rewards for this token
        _harvest(collectionAddress, _msgSender(), tokenId);

        // Apply a small burn fee from the user's balance to prevent value drain.
        require(balanceOf(_msgSender()) >= unstakeBurnFee, "CATA: Insufficient CATA for unstake fee");
        _burn(_msgSender(), unstakeBurnFee);

        info.currentlyStaked = false;

        // Remove token from the user's portfolio via swap-and-pop
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

    // ---------------------- Harvest (safe) ----------------------
    function _harvest(address collectionAddress, address user, uint256 tokenId) internal {
        StakeInfo storage info = stakeLog[collectionAddress][user][tokenId];
        uint256 rewardAmount = pendingRewards(collectionAddress, user, tokenId);

        if (rewardAmount > 0) {
            uint256 dynamicHarvestBurnFeeRate = _getDynamicHarvestBurnFeeRate();
            uint256 burnAmount = (rewardAmount * dynamicHarvestBurnFeeRate) / 100;
            uint256 payoutAmount = rewardAmount - burnAmount;

            // Mint full reward to user, then burn the burn portion from the user's balance.
            // This ensures tokens exist before attempting any burn.
            _mint(user, rewardAmount);

            if (burnAmount > 0) {
                _burn(user, burnAmount);
                burnedCatalystByCollection[collectionAddress] += burnAmount;
            }

            info.lastHarvestBlock = block.number;

            emit RewardsHarvested(user, collectionAddress, payoutAmount, burnAmount);
        }
    }

    // Batch harvest with limit (safer than unbounded harvestAll)
    function harvestBatch(address collectionAddress, uint256[] calldata tokenIds) external nonReentrant {
        require(tokenIds.length > 0, "CATA: No tokenIds provided");
        require(tokenIds.length <= MAX_HARVEST_BATCH, "CATA: Batch too large");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            _harvest(collectionAddress, _msgSender(), tokenIds[i]);
        }
    }

    // ---------------------- Pending rewards (clarified math) ----------------------
    function pendingRewards(address collectionAddress, address owner, uint256 tokenId) public view returns (uint256) {
        StakeInfo memory info = stakeLog[collectionAddress][owner][tokenId];
        if (!info.currentlyStaked || baseRewardRate == 0 || totalStakedNFTsCount == 0) {
            return 0;
        }

        // If it's a term stake and the deadline has passed, return 0.
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) {
            return 0;
        }

        uint256 blocksPassedSinceLastHarvest = block.number - info.lastHarvestBlock;

        // Core dynamic calculation
        // Interpret baseRewardRate as "wei per rewardPeriod" where rewardPeriod = numberOfBlocksPerRewardUnit.
        // rewardPerBlock = baseRewardRate / numberOfBlocksPerRewardUnit
        // rewardAmount = blocksPassedSinceLastHarvest * rewardPerBlock / totalStakedNFTsCount
        // Reordered to avoid precision loss: multiply before dividing where safe.
        // WARNING: baseRewardRate units must be chosen carefully off-chain (e.g., wei-per-day).
        uint256 rewardPerBlockTimes1 = baseRewardRate; // already in wei units per period
        uint256 numerator = blocksPassedSinceLastHarvest * rewardPerBlockTimes1;
        uint256 rewardAmount = (numerator / numberOfBlocksPerRewardUnit) / totalStakedNFTsCount;

        return rewardAmount;
    }

    // ---------------------- Admin setters (restricted) ----------------------
    function setBaseRewardRate(uint256 _newRate) external onlyRole(CONTRACT_ADMIN_ROLE) {
        uint256 old = baseRewardRate;
        baseRewardRate = _newRate;
        emit BaseRewardRateUpdated(old, _newRate);
    }

    function setWelcomeBonusBaseRate(uint256 _newRate) external onlyRole(CONTRACT_ADMIN_ROLE) {
        uint256 old = welcomeBonusBaseRate;
        welcomeBonusBaseRate = _newRate;
        emit WelcomeBonusBaseRateUpdated(old, _newRate);
    }

    function setWelcomeBonusIncrementPerNFT(uint256 _increment) external onlyRole(CONTRACT_ADMIN_ROLE) {
        uint256 old = welcomeBonusIncrementPerNFT;
        welcomeBonusIncrementPerNFT = _increment;
        emit WelcomeBonusIncrementUpdated(old, _increment);
    }

    function setHarvestBurnFeeRate(uint256 _rate) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_rate <= 100, "CATA: Rate cannot be more than 100");
        uint256 old = initialHarvestBurnFeeRate;
        initialHarvestBurnFeeRate = _rate;
        emit HarvestBurnFeeRateUpdated(old, _rate);
    }

    function setHarvestRateAdjustmentFactor(uint256 _factor) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_factor > 0, "CATA: Factor must be greater than zero");
        uint256 old = harvestRateAdjustmentFactor;
        harvestRateAdjustmentFactor = _factor;
        emit HarvestRateAdjustmentFactorUpdated(old, _factor);
    }

    function setTermDurationBlocks(uint256 _blocks) external onlyRole(CONTRACT_ADMIN_ROLE) {
        uint256 old = termDurationBlocks;
        termDurationBlocks = _blocks;
        emit TermDurationBlocksUpdated(old, _blocks);
    }

    function setUnstakeBurnFee(uint256 _fee) external onlyRole(CONTRACT_ADMIN_ROLE) {
        uint256 old = unstakeBurnFee;
        unstakeBurnFee = _fee;
        emit UnstakeBurnFeeUpdated(old, _fee);
    }

    function setStakingCooldownBlocks(uint256 _blocks) external onlyRole(CONTRACT_ADMIN_ROLE) {
        uint256 old = stakingCooldownBlocks;
        stakingCooldownBlocks = _blocks;
        emit StakingCooldownBlocksUpdated(old, _blocks);
    }

    function setMinBurnContributionForVote(uint256 _min) external onlyRole(CONTRACT_ADMIN_ROLE) {
        uint256 old = minBurnContributionForVote;
        minBurnContributionForVote = _min;
        emit MinBurnContributionForVoteUpdated(old, _min);
    }

    // ---------------------- Getters ----------------------
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

    // ---------------------- ERC721 Receiver ----------------------
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
