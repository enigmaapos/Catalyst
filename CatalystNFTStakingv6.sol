// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title CatalystNFTStaking 
 * @notice NFT-neutral staking + deflationary token + verified/unverified collections + top-100 leaderboard + quarterly bonus
 */
contract CatalystNFTStaking is
    ERC20,
    AccessControl,
    ReentrancyGuard,
    Pausable,
    IERC721Receiver
{
    // --------------------
    // Roles
    // --------------------
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // --------------------
    // Structs
    // --------------------
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

    // --------------------
    // State
    // --------------------
    // Collections
    mapping(address => CollectionConfig) public collectionConfigs;
    mapping(address => bool) public isVerifiedCollection; // false = unverified by default

    // Staking: collection => user => tokenId => StakeInfo
    mapping(address => mapping(address => mapping(uint256 => StakeInfo))) public stakeLog;
    // collection => user => tokenIds[]
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser;
    // collection => user => tokenId => index in portfolio array
    mapping(address => mapping(address => mapping(uint256 => uint256))) public indexOfTokenIdInStakePortfolio;

    // Welcome bonus per NFT token (collection => tokenId => bool)
    mapping(address => mapping(uint256 => bool)) public welcomeBonusCollected;

    // Burn accounting
    mapping(address => uint256) public burnedCatalystByCollection; // for collection-attributed burns
    mapping(address => uint256) public burnedByUser; // user-attributed burns
    uint256 public totalBurnedCATA;

    // Leaderboard (top 100)
    uint256 public constant TOP_TRACKED = 100;
    address[TOP_TRACKED] public topBurners;
    uint256[TOP_TRACKED] public topBurnedAmounts;
    uint256 public trackedCount;
    mapping(address => uint256) public burnerIndexPlusOne; // index+1, 0 means not tracked

    // Treasury (internal)
    uint256 public treasuryBalance;
    uint256 public constant DEPLOYER_FEE_SHARE_RATE = 10; // of the 10% non-burn portion (10% -> 1% overall)
    address public immutable deployerAddress;

    // Rewards & parameters
    uint256 public numberOfBlocksPerRewardUnit; // blocks per "reward unit"
    uint256 public baseRewardRate; // reward units
    uint256 public rewardRateIncrementPerNFT;
    uint256 public welcomeBonusBaseRate;
    uint256 public welcomeBonusIncrementPerNFT;
    uint256 public emissionCap; // optional cap on minting by contract
    bool public mintingEnabled;
    uint256 public totalMintedByContract;

    // Fees & durations
    uint256 public collectionRegistrationFee;
    uint256 public initialCollectionFee;
    uint256 public feeMultiplier;
    uint256 public unstakeBurnFee;
    uint256 public termDurationBlocks;
    uint256 public stakingCooldownBlocks;
    uint256 public initialHarvestBurnFeeRate;
    uint256 public harvestRateAdjustmentFactor;

    // Governance basics
    uint256 public minBurnContributionForVote;

    // Quarterly bonus
    uint256 public lastQuarterlyDistributionBlock;
    uint256 public quarterlyBlocks; // e.g., ~2.6M for 90 days on Polygon
    uint256 public bonusCapPercent; // percent of treasury distributed per quarter (e.g., 5)

    // Events
    event CollectionRegistered(address indexed collection, address indexed registrar, uint256 fee, bool verified);
    event CollectionUpgraded(address indexed collection);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event RewardsHarvested(address indexed user, address indexed collection, uint256 payout, uint256 burned);
    event PermanentStakeFeePaid(address indexed staker, uint256 feeAmount);
    event BurnedByUser(address indexed user, uint256 amount, address indexed collection);
    event BonusDistributed(uint256 pool, uint256 winners, uint256 timestamp);

    // --------------------
    // Constructor
    // --------------------
    constructor(
        address _owner,
        address _treasury, // not used separately; internal vault is contract itself; _treasury kept for potential future use
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
        uint256 _emissionCap,
        uint256 _quarterlyBlocks,
        uint256 _bonusCapPercent
    ) ERC20("Catalyst", "CATA") {
        require(_owner != address(0), "CATA: invalid owner");

        // initial supply to owner
        _mint(_owner, 25_185_000 * 10 ** 18);

        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        _setupRole(CONTRACT_ADMIN_ROLE, _owner);

        deployerAddress = _owner;

        // set params
        initialCollectionFee = _initialCollectionFee;
        feeMultiplier = _feeMultiplier;
        rewardRateIncrementPerNFT = _rewardRateIncrementPerNFT;
        welcomeBonusBaseRate = _welcomeBonusBaseRate;
        welcomeBonusIncrementPerNFT = _welcomeBonusIncrementPerNFT;
        initialHarvestBurnFeeRate = _initialHarvestBurnFeeRate;
        termDurationBlocks = _termDurationBlocks;
        collectionRegistrationFee = _collectionRegistrationFee;
        unstakeBurnFee = _unstakeBurnFee;
        stakingCooldownBlocks = _stakingCooldownBlocks;
        harvestRateAdjustmentFactor = _harvestRateAdjustmentFactor;
        minBurnContributionForVote = _minBurnContributionForVote;

        numberOfBlocksPerRewardUnit = 18782; // ~1 day (configurable)
        mintingEnabled = true;
        emissionCap = _emissionCap;
        totalMintedByContract = 0;

        quarterlyBlocks = _quarterlyBlocks;
        bonusCapPercent = _bonusCapPercent;
    }

    // --------------------
    // Modifiers
    // --------------------
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: staking cooldown");
        _;
    }

    // track last stake by user to enforce cooldown
    mapping(address => uint256) public lastStakingBlock;

    // --------------------
    // Math helpers
    // --------------------
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

    // dynamic permanent stake fee
    function _getDynamicPermanentStakeFee() public view returns (uint256) {
        return initialCollectionFee + (_sqrt(totalStakedNFTsCount) * feeMultiplier);
    }

    // dynamic harvest burn fee rate
    function _getDynamicHarvestBurnFeeRate() public view returns (uint256) {
        if (harvestRateAdjustmentFactor == 0) return initialHarvestBurnFeeRate;
        uint256 rate = initialHarvestBurnFeeRate + (baseRewardRate / harvestRateAdjustmentFactor);
        return rate > 90 ? 90 : rate;
    }

    // --------------------
    // Emission control
    // --------------------
    function _mintWithCap(address to, uint256 amount) internal {
        require(mintingEnabled, "CATA: minting disabled");
        if (emissionCap > 0) {
            require(totalMintedByContract + amount <= emissionCap, "CATA: emission cap");
        }
        totalMintedByContract += amount;
        _mint(to, amount);
    }

    // --------------------
    // Leaderboard (top 100) maintenance
    // Called when burnedByUser increases
    // --------------------
    function _maybeAddOrUpdateLeaderboard(address user) internal {
        uint256 amount = burnedByUser[user];
        if (amount == 0) return;

        uint256 idxPlusOne = burnerIndexPlusOne[user];
        if (idxPlusOne > 0) {
            uint256 idx = idxPlusOne - 1;
            topBurnedAmounts[idx] = amount;
            // bubble up if needed
            while (idx > 0 && topBurnedAmounts[idx] > topBurnedAmounts[idx - 1]) {
                (topBurnedAmounts[idx], topBurnedAmounts[idx - 1]) = (topBurnedAmounts[idx - 1], topBurnedAmounts[idx]);
                (topBurners[idx], topBurners[idx - 1]) = (topBurners[idx - 1], topBurners[idx]);
                burnerIndexPlusOne[topBurners[idx]] = idx + 1;
                burnerIndexPlusOne[topBurners[idx - 1]] = idx;
                idx--;
            }
            return;
        } else {
            if (trackedCount < TOP_TRACKED) {
                uint256 pos = trackedCount;
                topBurners[pos] = user;
                topBurnedAmounts[pos] = amount;
                burnerIndexPlusOne[user] = pos + 1;
                trackedCount++;
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
                uint256 lastIndex = trackedCount - 1;
                if (amount <= topBurnedAmounts[lastIndex]) return;
                address removed = topBurners[lastIndex];
                burnerIndexPlusOne[removed] = 0;
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

    // --------------------
    // Fee distribution (90% burn / 9% treasury / 1% deployer)
    // Caller must transfer feeAmount into contract prior to calling this internal function,
    // or ensure contract already has tokens (we do transfers in external functions).
    // If payer != address(0), attribute burn to payer for leaderboard/voting.
    // --------------------
    function _distributeFeeSplit(uint256 feeAmount, address collectionAddress, address payer) internal {
        if (feeAmount == 0) return;
        require(balanceOf(address(this)) >= feeAmount, "CATA: insufficient in contract");

        uint256 burnAmount = (feeAmount * 90) / 100;
        uint256 nonBurn = feeAmount - burnAmount; // 10%
        uint256 deployerShare = (nonBurn * DEPLOYER_FEE_SHARE_RATE) / 100; // e.g., 10% of 10% = 1%
        uint256 communityTreasuryShare = nonBurn - deployerShare;

        // burn from contract
        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
            burnedCatalystByCollection[collectionAddress] += burnAmount;
            totalBurnedCATA += burnAmount;
            if (payer != address(0)) {
                burnedByUser[payer] += burnAmount;
                emit BurnedByUser(payer, burnAmount, collectionAddress);
                _maybeAddOrUpdateLeaderboard(payer);
            }
        }

        // deployer share
        if (deployerShare > 0) {
            _transfer(address(this), deployerAddress, deployerShare);
        }

        // treasury share (kept inside contract)
        if (communityTreasuryShare > 0) {
            treasuryBalance += communityTreasuryShare;
            // tokens are already in contract from transfer into contract
        }
    }

    // --------------------
    // Collection registration (anyone)
    // --------------------
    function registerCollection(address collectionAddress) external nonReentrant whenNotPaused {
        require(collectionAddress != address(0), "CATA: invalid address");
        require(!collectionConfigs[collectionAddress].registered, "CATA: already registered");

        uint256 fee = collectionRegistrationFee;
        require(balanceOf(msg.sender) >= fee, "CATA: insufficient CATA for fee");

        // pull fee into contract
        _transfer(msg.sender, address(this), fee);
        // apply split and attribute burn to msg.sender
        _distributeFeeSplit(fee, collectionAddress, msg.sender);

        // register as unverified by default
        collectionConfigs[collectionAddress] = CollectionConfig({ totalStaked: 0, totalStakers: 0, registered: true });
        isVerifiedCollection[collectionAddress] = false;

        emit CollectionRegistered(collectionAddress, msg.sender, fee, false);
    }

    // --------------------
    // Upgrade collection to Verified (admin or governance should call)
    // Note: you can change this to be callable only by governance executor if you have one.
    // --------------------
    function upgradeCollectionToVerified(address collectionAddress) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(collectionConfigs[collectionAddress].registered, "CATA: not registered");
        require(!isVerifiedCollection[collectionAddress], "CATA: already verified");
        // optional checks can be enforced: burnedCatalystByCollection threshold, age, stakers, etc.
        isVerifiedCollection[collectionAddress] = true;
        emit CollectionUpgraded(collectionAddress);
    }

    // --------------------
    // Staking: term stake
    // --------------------
    function termStake(address collectionAddress, uint256 tokenId) external nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: collection not registered");

        // transfer NFT from user to contract (note: requires prior approval)
        IERC721(collectionAddress).safeTransferFrom(msg.sender, address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][msg.sender][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        info.lastHarvestBlock = block.number;
        info.currentlyStaked = true;
        info.isPermanent = false;
        info.unstakeDeadlineBlock = block.number + termDurationBlocks;

        CollectionConfig storage cfg = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][msg.sender].length == 0) {
            cfg.totalStakers += 1;
        }
        cfg.totalStaked += 1;
        totalStakedNFTsCount += 1;
        baseRewardRate += rewardRateIncrementPerNFT;

        stakePortfolioByUser[collectionAddress][msg.sender].push(tokenId);
        indexOfTokenIdInStakePortfolio[collectionAddress][msg.sender][tokenId] = stakePortfolioByUser[collectionAddress][msg.sender].length - 1;

        if (!welcomeBonusCollected[collectionAddress][tokenId]) {
            uint256 dynamicWelcomeBonus = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
            if (dynamicWelcomeBonus > 0) _mintWithCap(msg.sender, dynamicWelcomeBonus);
            welcomeBonusCollected[collectionAddress][tokenId] = true;
        }

        lastStakingBlock[msg.sender] = block.number;
        emit NFTStaked(msg.sender, collectionAddress, tokenId);
    }

    // --------------------
    // Staking: permanent stake (collect dynamic fee)
    // --------------------
    function permanentStake(address collectionAddress, uint256 tokenId) external nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: collection not registered");

        uint256 currentFee = _getDynamicPermanentStakeFee();
        require(balanceOf(msg.sender) >= currentFee, "CATA: insufficient CATA for fee");

        // transfer NFT first (so token held by contract)
        IERC721(collectionAddress).safeTransferFrom(msg.sender, address(this), tokenId);

        // transfer fee into contract and distribute (attribute burn to payer)
        _transfer(msg.sender, address(this), currentFee);
        _distributeFeeSplit(currentFee, collectionAddress, msg.sender);

        StakeInfo storage info = stakeLog[collectionAddress][msg.sender][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        info.lastHarvestBlock = block.number;
        info.currentlyStaked = true;
        info.isPermanent = true;
        info.unstakeDeadlineBlock = 0;

        CollectionConfig storage cfg = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][msg.sender].length == 0) {
            cfg.totalStakers += 1;
        }
        cfg.totalStaked += 1;
        totalStakedNFTsCount += 1;
        baseRewardRate += rewardRateIncrementPerNFT;

        stakePortfolioByUser[collectionAddress][msg.sender].push(tokenId);
        indexOfTokenIdInStakePortfolio[collectionAddress][msg.sender][tokenId] = stakePortfolioByUser[collectionAddress][msg.sender].length - 1;

        if (!welcomeBonusCollected[collectionAddress][tokenId]) {
            uint256 dynamicWelcomeBonus = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
            if (dynamicWelcomeBonus > 0) _mintWithCap(msg.sender, dynamicWelcomeBonus);
            welcomeBonusCollected[collectionAddress][tokenId] = true;
        }

        lastStakingBlock[msg.sender] = block.number;
        emit PermanentStakeFeePaid(msg.sender, currentFee);
        emit NFTStaked(msg.sender, collectionAddress, tokenId);
    }

    // --------------------
    // Unstake
    // --------------------
    function unstake(address collectionAddress, uint256 tokenId) external nonReentrant whenNotPaused {
        StakeInfo storage info = stakeLog[collectionAddress][msg.sender][tokenId];
        require(info.currentlyStaked, "CATA: not staked");
        if (!info.isPermanent) {
            require(block.number >= info.unstakeDeadlineBlock, "CATA: term not expired");
        }

        // harvest first
        _harvest(collectionAddress, msg.sender, tokenId);

        // collect unstake burn fee
        require(balanceOf(msg.sender) >= unstakeBurnFee, "CATA: insufficient for unstake fee");
        _transfer(msg.sender, address(this), unstakeBurnFee);
        _distributeFeeSplit(unstakeBurnFee, collectionAddress, msg.sender);

        // mark as unstaked and remove from portfolio
        info.currentlyStaked = false;

        uint256[] storage portfolio = stakePortfolioByUser[collectionAddress][msg.sender];
        uint256 indexToRemove = indexOfTokenIdInStakePortfolio[collectionAddress][msg.sender][tokenId];
        uint256 lastIndex = portfolio.length - 1;
        if (indexToRemove != lastIndex) {
            uint256 lastTokenId = portfolio[lastIndex];
            portfolio[indexToRemove] = lastTokenId;
            indexOfTokenIdInStakePortfolio[collectionAddress][msg.sender][lastTokenId] = indexToRemove;
        }
        portfolio.pop();
        delete indexOfTokenIdInStakePortfolio[collectionAddress][msg.sender][tokenId];

        // transfer NFT back to user
        IERC721(collectionAddress).safeTransferFrom(address(this), msg.sender, tokenId);

        // update collection counters
        CollectionConfig storage cfg = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][msg.sender].length == 0) {
            if (cfg.totalStakers > 0) cfg.totalStakers -= 1;
        }
        if (cfg.totalStaked > 0) cfg.totalStaked -= 1;
        if (totalStakedNFTsCount > 0) totalStakedNFTsCount -= 1;
        if (baseRewardRate >= rewardRateIncrementPerNFT) baseRewardRate -= rewardRateIncrementPerNFT;

        emit NFTUnstaked(msg.sender, collectionAddress, tokenId);
    }

    // --------------------
    // Harvest internal and batch
    // --------------------
    function _harvest(address collectionAddress, address user, uint256 tokenId) internal {
        StakeInfo storage info = stakeLog[collectionAddress][user][tokenId];
        uint256 rewardAmount = pendingRewards(collectionAddress, user, tokenId);
        if (rewardAmount == 0) {
            info.lastHarvestBlock = block.number;
            return;
        }

        // mint rewards into contract then burn portion and pay out
        _mintWithCap(address(this), rewardAmount);

        uint256 dynamicBurnRate = _getDynamicHarvestBurnFeeRate();
        uint256 burnAmount = (rewardAmount * dynamicBurnRate) / 100;
        uint256 payout = rewardAmount - burnAmount;

        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
            burnedCatalystByCollection[collectionAddress] += burnAmount;
            totalBurnedCATA += burnAmount;
            // Note: harvest burn is protocol attributed; not user-attributed to leaderboard
        }

        if (payout > 0) {
            _transfer(address(this), user, payout);
        }

        info.lastHarvestBlock = block.number;
        emit RewardsHarvested(user, collectionAddress, payout, burnAmount);
    }

    function harvestAll(address collectionAddress) external nonReentrant whenNotPaused {
        uint256[] memory stakedTokens = stakePortfolioByUser[collectionAddress][msg.sender];
        for (uint256 i = 0; i < stakedTokens.length; i++) {
            _harvest(collectionAddress, msg.sender, stakedTokens[i]);
        }
    }

    // --------------------
    // Pending rewards view
    // --------------------
    function pendingRewards(address collectionAddress, address owner, uint256 tokenId) public view returns (uint256) {
        StakeInfo memory info = stakeLog[collectionAddress][owner][tokenId];
        if (!info.currentlyStaked || baseRewardRate == 0 || totalStakedNFTsCount == 0) return 0;
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) return 0;
        uint256 blocksPassed = block.number - info.lastHarvestBlock;
        uint256 rewardPerUnit = (baseRewardRate * (10 ** 18)) / totalStakedNFTsCount;
        uint256 rewardAmount = (blocksPassed / numberOfBlocksPerRewardUnit) * rewardPerUnit;
        return rewardAmount;
    }

    // --------------------
    // Voluntary burn (user) - pay tokens into contract then distribution so burn attributed to user
    // --------------------
    function burnCATA(uint256 amount, address collectionAddress) external nonReentrant whenNotPaused {
        require(amount > 0, "CATA: zero");
        require(balanceOf(msg.sender) >= amount, "CATA: insufficient");

        _transfer(msg.sender, address(this), amount);
        _distributeFeeSplit(amount, collectionAddress, msg.sender);
    }

    // --------------------
    // Quarterly Bonus Distribution (top 10% of trackedCount, admin-triggered)
    // --------------------
    function distributeQuarterlyBonus() external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(block.number >= lastQuarterlyDistributionBlock + quarterlyBlocks, "CATA: too early");
        require(trackedCount > 0, "CATA: no tracked burners");

        uint256 pool = (treasuryBalance * bonusCapPercent) / 100;
        require(pool > 0, "CATA: pool empty");
        require(balanceOf(address(this)) >= pool, "CATA: insufficient pool");

        uint256 eligibleCount = trackedCount / 10; // top 10%
        if (eligibleCount == 0) eligibleCount = 1;

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < eligibleCount; i++) {
            totalWeight += topBurnedAmounts[i];
        }
        require(totalWeight > 0, "CATA: zero weight");

        // deduct from treausry accounting
        treasuryBalance -= pool;

        // distribute proportionally
        for (uint256 i = 0; i < eligibleCount; i++) {
            uint256 share = (pool * topBurnedAmounts[i]) / totalWeight;
            if (share > 0) _transfer(address(this), topBurners[i], share);
        }

        lastQuarterlyDistributionBlock = block.number;
        emit BonusDistributed(pool, eligibleCount, block.timestamp);
    }

    // --------------------
    // Simple governance helper (example)
    // Keep it simple: proposal by authorized burner; majority threshold 2 for demonstration (you can expand)
    // --------------------
    function proposeAndVote(uint256 newRate, address collectionAddress) external {
        require(burnedCatalystByCollection[collectionAddress] >= minBurnContributionForVote, "CATA: Not authorized voter");
        bytes32 proposalId = keccak256(abi.encodePacked("proposeBaseRewardRate", newRate));
        require(!hasVoted[proposalId][msg.sender], "CATA: Already voted");
        hasVoted[proposalId][msg.sender] = true;
        votesForProposal[proposalId] += 1;
        if (votesForProposal[proposalId] >= 2) {
            baseRewardRate = newRate;
            delete votesForProposal[proposalId];
        }
    }

    // --------------------
    // Admin setters (safeguarded)
    // --------------------
    function setCollectionRegistrationFee(uint256 fee) external onlyRole(CONTRACT_ADMIN_ROLE) {
        collectionRegistrationFee = fee;
    }
    function setUnstakeBurnFee(uint256 fee) external onlyRole(CONTRACT_ADMIN_ROLE) {
        unstakeBurnFee = fee;
    }
    function setTermDurationBlocks(uint256 blocks_) external onlyRole(CONTRACT_ADMIN_ROLE) {
        termDurationBlocks = blocks_;
    }
    function setStakingCooldownBlocks(uint256 blocks_) external onlyRole(CONTRACT_ADMIN_ROLE) {
        stakingCooldownBlocks = blocks_;
    }
    function setMinBurnContributionForVote(uint256 minBurn) external onlyRole(CONTRACT_ADMIN_ROLE) {
        minBurnContributionForVote = minBurn;
    }
    function setQuarterlyParams(uint256 blocks_, uint256 capPercent) external onlyRole(CONTRACT_ADMIN_ROLE) {
        quarterlyBlocks = blocks_;
        bonusCapPercent = capPercent;
    }
    function setMintingEnabled(bool flag) external onlyRole(CONTRACT_ADMIN_ROLE) {
        mintingEnabled = flag;
    }
    function setEmissionCap(uint256 cap) external onlyRole(CONTRACT_ADMIN_ROLE) {
        emissionCap = cap;
    }
    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }

    // --------------------
    // Getters & utility
    // --------------------
    function getTopBurners(uint256 n) external view returns (address[] memory addrs, uint256[] memory amounts) {
        if (n > trackedCount) n = trackedCount;
        addrs = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            addrs[i] = topBurners[i];
            amounts[i] = topBurnedAmounts[i];
        }
    }

    function getRegisteredCollections() external view returns (address[] memory arr) {
        // Not tracking a list; if you need a list, maintain an array/EnumerableSet when registering collections.
        arr = new address;
    }

    function getBurnedByUser(address user) external view returns (uint256) { return burnedByUser[user]; }
    function getBurnedByCollection(address collection) external view returns (uint256) { return burnedCatalystByCollection[collection]; }
    function getTreasuryBalance() external view returns (uint256) { return treasuryBalance; }
    function getDynamicPermanentStakeFee() external view returns (uint256) { return _getDynamicPermanentStakeFee(); }
    function getDynamicHarvestBurnFeeRate() external view returns (uint256) { return _getDynamicHarvestBurnFeeRate(); }
    function getTrackedCount() external view returns (uint256) { return trackedCount; }

    // --------------------
    // Rescue (admin)
    // --------------------
    function rescueERC721(address nft, uint256 tokenId, address to) external onlyRole(CONTRACT_ADMIN_ROLE) {
        IERC721(nft).safeTransferFrom(address(this), to, tokenId);
    }
    function rescueERC20(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) {
        _transfer(address(this), to, amount);
    }

    // --------------------
    // ERC721 Receiver
    // --------------------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
