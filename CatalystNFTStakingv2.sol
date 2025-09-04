// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  CatalystNFTStaking.sol — Updated
  - Fixes 8 issues reported by Var
  - Immutable 90/9/1 split enforced
  - registerCollection fixes totalBurned bug
  - Optional minting (mintingEnabled) or reward-pool fallback
  - Checks treasury allowance before pulling bonus funds
  - Off-chain mode toggle for heavy top-collection computation
  - Voting weight cap (maxVoteWeight) to limit whales
  - Correct unique staker accounting (totalStakersCount)
  - Try/catch protections on external token transfers
  - Enhanced validation & revert messages for better UX
*/

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IOwnable {
    function owner() external view returns (address);
}

interface IERC721Custom is IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address owner);
}

// Minimal mintable ERC20 interface — the CATA token MUST implement this if mintingEnabled = true
interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract CatalystNFTStaking is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Immutable fee split (basis points)
    uint256 public constant BURN_BP = 9000;    // 90.00%
    uint256 public constant TREASURY_BP = 900; // 9.00%
    uint256 public constant OWNER_BP = 100;    // 1.00%
    // sanity: BURN_BP + TREASURY_BP + OWNER_BP == 10000

    // Tokens & addresses
    IMintableERC20 public immutable cataToken;    // require this if mintingEnabled
    IERC20 public immutable cataTokenAsERC20;     // ERC20 view for transfers
    address public immutable deployerAddress;     // immutable 1% recipient
    address public treasuryAddress;               // treasury (receives 9%)

    // Reward minting configuration
    bool public mintingEnabled;                   // if true, contract will mint rewards (requires minter role)
    address public rewardPool;                    // fallback pool address (when mintingEnabled = false), must approve this contract

    // Protocol params (changeable by owner / governance)
    uint256 public baseRewardRatePerDay;
    uint256 public unstakeFeeRateBP;
    uint256 public harvestFeeRateBP;
    uint256 public constant MAX_BATCH = 50;

    // Registration fees
    uint256 public registrationFeeSmall;
    uint256 public registrationFeeMedium;
    uint256 public registrationFeeLarge;

    // Bonus distribution params
    uint256 public bonusDistributionInterval;
    uint256 public lastBonusDistribution;
    uint256 public treasuryBonusCapBP;
    uint256 public minBurnToQualifyBonus;
    uint256 public minStakedToQualifyBonus;

    // Governance params
    uint256 public proposalDuration;
    uint256 public governanceTopCollectionsPercent;

    // Off-chain mode: when true, skip on-chain top-collection computation and rely on off-chain winners
    bool public offChainTopComputationMode;

    // Anti-whale / voting caps
    uint256 public maxVoteWeight; // if > 0, caps a voter's weight to this amount
    // per-collection vote cap (optional; not used in this simplified voting flow)
    mapping(address => uint256) public perCollectionVoteCap;

    // Storage
    struct StakeInfo {
        address owner;
        uint256 timestamp;
        bool permanent;
        bool staked;
        uint256 lastHarvest;
    }

    struct CollectionConfig {
        bool registered;
        bool verified;
        uint256 stakedCount;
        uint256 totalBurned;   // tracked burned attributed to this collection
        uint256 declaredSupply;
        uint256 surchargeEscrow;
    }

    mapping(address => mapping(uint256 => StakeInfo)) public stakeLog; // collection => tokenId => StakeInfo
    mapping(address => CollectionConfig) public collectionConfigs;
    EnumerableSet.AddressSet private _registeredCollections;

    // user portfolio: collection => user => tokenIds
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser;
    mapping(address => mapping(address => mapping(uint256 => uint256))) private _portfolioIndex; // collection => user => tokenId -> idx+1

    // Unique staker tracking
    mapping(address => uint256) public userTotalStakedCount; // total NFTs staked across all collections by user
    uint256 public totalStakersCount;

    // Burn tracking
    mapping(address => uint256) public burnedCatalystByAddress;
    mapping(address => uint256) public burnedCatalystByCollection;
    uint256 public totalBurnedCATA;

    // Governance
    struct Proposal {
        string title;
        string description;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 startTime;
        uint256 endTime;
        bool executed;
    }
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    uint256 public proposalCount;

    // Totals
    uint256 public totalStakedNFTsCount;

    // Events
    event CollectionRegistered(address indexed collection, address indexed registrar, uint256 feePaid, uint256 declaredSupply, bool verified);
    event Stake(address indexed user, address indexed collection, uint256 indexed tokenId, bool permanent);
    event BatchStake(address indexed user, address indexed collection, uint256 count, bool permanent);
    event Unstake(address indexed user, address indexed collection, uint256 indexed tokenId);
    event BatchUnstake(address indexed user, address indexed collection, uint256 count);
    event Burned(address indexed user, uint256 amount, address indexed collection);
    event ProposalCreated(uint256 indexed id, string title, uint256 startTime, uint256 endTime);
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed id, bool passed);
    event BonusDistributed(uint256 totalAmount, uint256 winnersCount, uint256 timestamp);
    event Harvested(address indexed user, address indexed collection, uint256 indexed tokenId, uint256 reward, uint256 fee);
    event OffChainTopModeToggled(bool enabled);
    event MintingModeToggled(bool enabled);
    event RewardPoolSet(address indexed pool);

    // Constructor
    constructor(
        address _cataToken,
        address _treasury,
        address _deployer,
        uint256 _baseRewardRatePerDay,
        uint256 _unstakeFeeRateBP,
        uint256 _harvestFeeRateBP,
        uint256 _registrationFeeSmall,
        uint256 _registrationFeeMedium,
        uint256 _registrationFeeLarge,
        uint256 _bonusDistributionInterval,
        uint256 _treasuryBonusCapBP,
        uint256 _minBurnToQualifyBonus,
        uint256 _minStakedToQualifyBonus,
        uint256 _proposalDuration,
        uint256 _governanceTopCollectionsPercent
    ) {
        require(_cataToken != address(0), "CATA: zero token");
        require(_treasury != address(0), "CAT: zero treasury");
        require(_deployer != address(0), "CAT: zero deployer");
        require(_unstakeFeeRateBP <= 10000 && _harvestFeeRateBP <= 10000, "CAT: bad fee bp");
        require(_treasuryBonusCapBP <= 10000, "CAT: bad bonus cap bp");

        cataToken = IMintableERC20(_cataToken);
        cataTokenAsERC20 = IERC20(_cataToken);
        treasuryAddress = _treasury;
        deployerAddress = _deployer;

        baseRewardRatePerDay = _baseRewardRatePerDay;
        unstakeFeeRateBP = _unstakeFeeRateBP;
        harvestFeeRateBP = _harvestFeeRateBP;

        registrationFeeSmall = _registrationFeeSmall;
        registrationFeeMedium = _registrationFeeMedium;
        registrationFeeLarge = _registrationFeeLarge;

        bonusDistributionInterval = _bonusDistributionInterval;
        treasuryBonusCapBP = _treasuryBonusCapBP;
        minBurnToQualifyBonus = _minBurnToQualifyBonus;
        minStakedToQualifyBonus = _minStakedToQualifyBonus;

        proposalDuration = _proposalDuration;
        governanceTopCollectionsPercent = _governanceTopCollectionsPercent;

        // Defaults
        offChainTopComputationMode = false;
        mintingEnabled = true; // default to true; must grant minter role on token
        rewardPool = address(0);
        maxVoteWeight = 0; // 0 = no cap
    }

    // Modifiers
    modifier onlyRegistered(address collection) {
        require(collectionConfigs[collection].registered, "CAT: collection not registered");
        _;
    }

    // -----------------------------
    // Admin setters (owner)
    // -----------------------------
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "CAT: zero treasury");
        treasuryAddress = _treasury;
    }

    function setBaseRewardRatePerDay(uint256 v) external onlyOwner { baseRewardRatePerDay = v; }
    function setUnstakeFeeRateBP(uint256 bp) external onlyOwner { require(bp <= 10000, "CAT: bp>10000"); unstakeFeeRateBP = bp; }
    function setHarvestFeeRateBP(uint256 bp) external onlyOwner { require(bp <= 10000, "CAT: bp>10000"); harvestFeeRateBP = bp; }

    function setRegistrationFees(uint256 smallFee, uint256 medFee, uint256 largeFee) external onlyOwner {
        registrationFeeSmall = smallFee;
        registrationFeeMedium = medFee;
        registrationFeeLarge = largeFee;
    }

    function setBonusSettings(uint256 interval, uint256 capBP, uint256 minBurn, uint256 minStaked) external onlyOwner {
        bonusDistributionInterval = interval;
        treasuryBonusCapBP = capBP;
        minBurnToQualifyBonus = minBurn;
        minStakedToQualifyBonus = minStaked;
    }

    function setProposalDuration(uint256 secs) external onlyOwner { proposalDuration = secs; }
    function setGovernanceTopCollectionsPercent(uint256 p) external onlyOwner { governanceTopCollectionsPercent = p; }

    function toggleOffChainTopComputationMode(bool enabled) external onlyOwner {
        offChainTopComputationMode = enabled;
        emit OffChainTopModeToggled(enabled);
    }

    function setMintingEnabled(bool enabled) external onlyOwner {
        mintingEnabled = enabled;
        emit MintingModeToggled(enabled);
    }

    function setRewardPool(address pool) external onlyOwner {
        rewardPool = pool;
        emit RewardPoolSet(pool);
    }

    function setMaxVoteWeight(uint256 cap) external onlyOwner {
        maxVoteWeight = cap;
    }

    function setPerCollectionVoteCap(address collection, uint256 cap) external onlyOwner {
        perCollectionVoteCap[collection] = cap;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // -----------------------------
    // Internal: split & distribute (immutable 90/9/1)
    // - amount must be already in contract (or pulled into contract before calling)
    // - returns burnShare for convenience
    // -----------------------------
    function _splitAndDistributeFee(address originUser, uint256 amount, address collection) internal returns (uint256 burnShare) {
        require(amount > 0, "CAT: zero amount");

        burnShare = (amount * BURN_BP) / 10000;
        uint256 treasuryShare = (amount * TREASURY_BP) / 10000;
        uint256 ownerShare = amount - burnShare - treasuryShare; // OWNER_BP portion

        // 1) Burn
        address dead = address(0x000000000000000000000000000000000000dEaD);
        cataTokenAsERC20.safeTransfer(dead, burnShare);

        // 2) Treasury
        if (treasuryShare > 0) cataTokenAsERC20.safeTransfer(treasuryAddress, treasuryShare);

        // 3) Owner / deployer
        if (ownerShare > 0) cataTokenAsERC20.safeTransfer(deployerAddress, ownerShare);

        // bookkeeping
        burnedCatalystByAddress[originUser] += burnShare;
        if (collection != address(0)) {
            burnedCatalystByCollection[collection] += burnShare;
            // keep collectionConfigs[collection].totalBurned up-to-date (if registered)
            if (collectionConfigs[collection].registered) {
                collectionConfigs[collection].totalBurned += burnShare;
            }
        }
        totalBurnedCATA += burnShare;

        emit Burned(originUser, burnShare, collection);
        return burnShare;
    }

    // -----------------------------
    // Registration (updated & fixed)
    // - declaredSupply must be >0 and <= 100k
    // - anyone can register
    // - if caller not owner or collection owner => verified forced to false
    // - fee is pulled then split 90/9/1 (immutable)
    // - totalBurned set correctly from burnedCatalystByCollection AFTER split
    // -----------------------------
    function registerCollection(address collection, uint256 declaredSupply, bool verified) external whenNotPaused nonReentrant {
        require(collection != address(0), "CAT: zero collection");
        require(!collectionConfigs[collection].registered, "CAT: already registered");
        require(declaredSupply > 0 && declaredSupply <= 100000, "CAT: declaredSupply out of range");

        bool isAdmin = msg.sender == owner();
        bool isCollectionOwner = false;

        // check collection owner via ownerOf(0) and fallback to Ownable.owner()
        try IERC721Custom(collection).ownerOf(0) returns (address ownerAddr) {
            if (ownerAddr == msg.sender) isCollectionOwner = true;
        } catch {
            try IOwnable(collection).owner() returns (address contractOwner) {
                if (contractOwner == msg.sender) isCollectionOwner = true;
            } catch {
                isCollectionOwner = false;
            }
        }

        if (!isAdmin && !isCollectionOwner) {
            verified = false;
        }

        uint256 fee = _registrationFeeBySupply(declaredSupply);
        require(fee > 0, "CAT: no registration fee set");

        // pull fee into contract (must be approved)
        cataTokenAsERC20.safeTransferFrom(msg.sender, address(this), fee);

        // split & distribute (burns, treasury, owner)
        uint256 burnShare = _splitAndDistributeFee(msg.sender, fee, collection);

        // register and set totalBurned correctly
        uint256 collectionBurnSoFar = burnedCatalystByCollection[collection]; // includes burnShare
        collectionConfigs[collection] = CollectionConfig({
            registered: true,
            verified: verified,
            stakedCount: 0,
            totalBurned: collectionBurnSoFar,
            declaredSupply: declaredSupply,
            surchargeEscrow: 0
        });
        _registeredCollections.add(collection);

        emit CollectionRegistered(collection, msg.sender, fee, declaredSupply, verified);
    }

    function _registrationFeeBySupply(uint256 declaredSupply) internal view returns (uint256) {
        if (declaredSupply == 0) {
            return registrationFeeLarge;
        } else if (declaredSupply <= 5000) {
            return registrationFeeSmall;
        } else if (declaredSupply <= 10000) {
            return registrationFeeMedium;
        } else {
            return registrationFeeLarge;
        }
    }

    // -----------------------------
    // Stake (single & batch) with unique staker accounting
    // -----------------------------
    function termStake(address collection, uint256 tokenId) external whenNotPaused nonReentrant onlyRegistered(collection) {
        _stake(collection, tokenId, false);
    }
    function permanentStake(address collection, uint256 tokenId) external whenNotPaused nonReentrant onlyRegistered(collection) {
        _stake(collection, tokenId, true);
    }
    function termStakeBatch(address collection, uint256[] calldata tokenIds) external whenNotPaused nonReentrant onlyRegistered(collection) {
        _batchStake(collection, tokenIds, false);
    }
    function permanentStakeBatch(address collection, uint256[] calldata tokenIds) external whenNotPaused nonReentrant onlyRegistered(collection) {
        _batchStake(collection, tokenIds, true);
    }

    function _batchStake(address collection, uint256[] calldata tokenIds, bool permanent) internal {
        uint256 len = tokenIds.length;
        require(len > 0 && len <= MAX_BATCH, "CAT: invalid batch size");
        for (uint256 i = 0; i < len; i++) {
            _stake(collection, tokenIds[i], permanent);
        }
        emit BatchStake(msg.sender, collection, len, permanent);
    }

    function _stake(address collection, uint256 tokenId, bool permanent) internal {
        IERC721 nft = IERC721(collection);

        // verify owner
        require(nft.ownerOf(tokenId) == msg.sender, "CAT: caller not owner of token");

        // transfer NFT to this contract safely using try/catch
        try nft.transferFrom(msg.sender, address(this), tokenId) {
            // ok
        } catch {
            revert("CAT: NFT transfer failed");
        }

        // record stake
        stakeLog[collection][tokenId] = StakeInfo({
            owner: msg.sender,
            timestamp: block.timestamp,
            permanent: permanent,
            staked: true,
            lastHarvest: block.timestamp
        });

        // add to portfolio
        _portfolioIndex[collection][msg.sender][tokenId] = stakePortfolioByUser[collection][msg.sender].length + 1;
        stakePortfolioByUser[collection][msg.sender].push(tokenId);

        // update unique staker accounting
        if (userTotalStakedCount[msg.sender] == 0) {
            totalStakersCount += 1;
        }
        userTotalStakedCount[msg.sender] += 1;

        // totals
        totalStakedNFTsCount += 1;
        collectionConfigs[collection].stakedCount += 1;

        emit Stake(msg.sender, collection, tokenId, permanent);
    }

    // -----------------------------
    // Harvest: reward calculation & distribution
    // - If mintingEnabled == true -> mint to this contract
    // - Else -> pull from rewardPool (rewardPool must approve this contract)
    // - Fee on harvest (harvestFeeRateBP) is split 90/9/1
    // -----------------------------
    function pendingRewards(address collection, uint256 tokenId) public view returns (uint256) {
        StakeInfo memory s = stakeLog[collection][tokenId];
        if (!s.staked) return 0;
        uint256 elapsed = block.timestamp - s.lastHarvest;
        return (baseRewardRatePerDay * elapsed) / 1 days;
    }

    function harvest(address collection, uint256 tokenId) public whenNotPaused nonReentrant onlyRegistered(collection) returns (uint256 netPayout) {
        StakeInfo storage s = stakeLog[collection][tokenId];
        require(s.staked && s.owner == msg.sender, "CAT: not staker");

        uint256 reward = pendingRewards(collection, tokenId);
        if (reward == 0) {
            s.lastHarvest = block.timestamp;
            return 0;
        }

        // obtain reward tokens into this contract
        if (mintingEnabled) {
            // requires cataToken to allow this contract to mint
            cataToken.mint(address(this), reward);
        } else {
            require(rewardPool != address(0), "CAT: rewardPool not set");
            uint256 allowance = cataTokenAsERC20.allowance(rewardPool, address(this));
            require(allowance >= reward, "CAT: rewardPool allowance insufficient");
            // pull from pool
            cataTokenAsERC20.safeTransferFrom(rewardPool, address(this), reward);
        }

        // compute fee and net payout
        uint256 feeAmount = (reward * harvestFeeRateBP) / 10000;
        uint256 net = reward - feeAmount;

        // distribute fee using immutable split (pulls from this contract's balance)
        if (feeAmount > 0) {
            _splitAndDistributeFee(msg.sender, feeAmount, collection);
        }

        // send net to user
        if (net > 0) {
            cataTokenAsERC20.safeTransfer(msg.sender, net);
        }

        s.lastHarvest = block.timestamp;

        emit Harvested(msg.sender, collection, tokenId, reward, feeAmount);
        return net;
    }

    function harvestBatch(address collection, uint256[] calldata tokenIds) external whenNotPaused nonReentrant onlyRegistered(collection) returns (uint256 totalNet) {
        require(tokenIds.length > 0 && tokenIds.length <= MAX_BATCH, "CAT: invalid batch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            totalNet += harvest(collection, tokenIds[i]);
        }
    }

    // -----------------------------
    // Unstake (fee applied)
    // - Harvest first, then collect unstake fee pulled from user, split 90/9/1
    // -----------------------------
    function unstake(address collection, uint256 tokenId) public whenNotPaused nonReentrant onlyRegistered(collection) {
        StakeInfo storage s = stakeLog[collection][tokenId];
        require(s.staked && s.owner == msg.sender, "CAT: not staker");

        // harvest pending rewards
        harvest(collection, tokenId);

        // compute unstake fee (example basis using baseRewardRatePerDay)
        uint256 fee = (baseRewardRatePerDay * unstakeFeeRateBP) / 10000;
        if (fee > 0) {
            // pull fee from user (approval required)
            cataTokenAsERC20.safeTransferFrom(msg.sender, address(this), fee);
            _splitAndDistributeFee(msg.sender, fee, collection);
        }

        // return NFT
        try IERC721(collection).transferFrom(address(this), msg.sender, tokenId) {
            // ok
        } catch {
            revert("CAT: return NFT failed");
        }

        // mark unstaked
        s.staked = false;

        // remove from portfolio
        _removeFromPortfolio(collection, msg.sender, tokenId);

        // update unique staker accounting
        if (userTotalStakedCount[msg.sender] > 0) {
            userTotalStakedCount[msg.sender] -= 1;
            if (userTotalStakedCount[msg.sender] == 0) {
                // user has no more stakes across protocol
                if (totalStakersCount > 0) totalStakersCount -= 1;
            }
        }

        // totals
        if (totalStakedNFTsCount > 0) totalStakedNFTsCount -= 1;
        if (collectionConfigs[collection].stakedCount > 0) collectionConfigs[collection].stakedCount -= 1;

        emit Unstake(msg.sender, collection, tokenId);
    }

    function unstakeBatch(address collection, uint256[] calldata tokenIds) external whenNotPaused nonReentrant onlyRegistered(collection) {
        uint256 len = tokenIds.length;
        require(len > 0 && len <= MAX_BATCH, "CAT: invalid batch");
        for (uint256 i = 0; i < len; i++) {
            unstake(collection, tokenIds[i]);
        }
        emit BatchUnstake(msg.sender, collection, len);
    }

    // -----------------------------
    // Voluntary burn (split 90/9/1)
    // - User must approve this contract to pull amount
    // -----------------------------
    function burnCATA(uint256 amount, address collection) external whenNotPaused nonReentrant {
        require(amount > 0, "CAT: zero burn");
        cataTokenAsERC20.safeTransferFrom(msg.sender, address(this), amount);
        _splitAndDistributeFee(msg.sender, amount, collection);
    }

    // -----------------------------
    // Portfolio helpers
    // -----------------------------
    function _removeFromPortfolio(address collection, address user, uint256 tokenId) internal {
        uint256 idxPlusOne = _portfolioIndex[collection][user][tokenId];
        require(idxPlusOne != 0, "CAT: not in portfolio");
        uint256 idx = idxPlusOne - 1;

        uint256[] storage arr = stakePortfolioByUser[collection][user];
        uint256 lastTokenId = arr[arr.length - 1];
        if (idx != arr.length - 1) {
            arr[idx] = lastTokenId;
            _portfolioIndex[collection][user][lastTokenId] = idx + 1;
        }
        arr.pop();
        delete _portfolioIndex[collection][user][tokenId];
    }

    function getUserStakedTokens(address collection, address user) external view returns (uint256[] memory) {
        return stakePortfolioByUser[collection][user];
    }

    // -----------------------------
    // Governance (minimal)
    // - createProposal / voteOnProposal / executeProposal
    // - vote weight = burnedCatalystByAddress capped by maxVoteWeight (if >0)
    // - eligibility: burned >= threshold OR stake in top X% collections (on-chain) unless offChainTopComputationMode
    // -----------------------------
    uint256 public minBurnThresholdForVote = 1 ether;
    function setMinBurnThresholdForVote(uint256 v) external onlyOwner { minBurnThresholdForVote = v; }

    function createProposal(string calldata title, string calldata description) external whenNotPaused {
        proposals[proposalCount] = Proposal({
            title: title,
            description: description,
            votesFor: 0,
            votesAgainst: 0,
            startTime: block.timestamp,
            endTime: block.timestamp + proposalDuration,
            executed: false
        });
        emit ProposalCreated(proposalCount, title, block.timestamp, block.timestamp + proposalDuration);
        proposalCount++;
    }

    function isVoterEligible(address voter) public view returns (bool) {
        if (burnedCatalystByAddress[voter] >= minBurnThresholdForVote) return true;
        if (offChainTopComputationMode) {
            // in off-chain mode, eligibility via top-collection stake can't be computed on-chain; require burn threshold
            return false;
        }
        (address[] memory topCollections, ) = _computeTopCollectionsByPercent(governanceTopCollectionsPercent);
        if (topCollections.length == 0) return false;
        for (uint256 i = 0; i < topCollections.length; i++) {
            if (stakePortfolioByUser[topCollections[i]][voter].length > 0) return true;
        }
        return false;
    }

    function voteOnProposal(uint256 id, bool support) external whenNotPaused nonReentrant {
        require(id < proposalCount, "CAT: invalid proposal id");
        Proposal storage p = proposals[id];
        require(block.timestamp >= p.startTime && block.timestamp < p.endTime, "CAT: voting closed");
        require(!hasVoted[id][msg.sender], "CAT: already voted");
        require(isVoterEligible(msg.sender), "CAT: not eligible to vote");

        uint256 rawWeight = burnedCatalystByAddress[msg.sender];
        require(rawWeight > 0, "CAT: no weight");

        uint256 weight = rawWeight;
        if (maxVoteWeight > 0 && weight > maxVoteWeight) weight = maxVoteWeight;

        if (support) p.votesFor += weight; else p.votesAgainst += weight;
        hasVoted[id][msg.sender] = true;
        emit Voted(id, msg.sender, support, weight);
    }

    // executeProposal only sets executed flag and emits event; callers may perform on-chain actions via owner multisig after
    function executeProposal(uint256 id, uint256 minVotesForExecution) external whenNotPaused nonReentrant {
        require(id < proposalCount, "CAT: invalid proposal id");
        Proposal storage p = proposals[id];
        require(block.timestamp >= p.endTime, "CAT: voting not ended");
        require(!p.executed, "CAT: already executed");

        bool passed = (p.votesFor > p.votesAgainst) && (p.votesFor >= minVotesForExecution);
        p.executed = true;
        emit ProposalExecuted(id, passed);
    }

    // -----------------------------
    // Top collections helpers (on-chain) — expensive for large sets
    // If offChainTopComputationMode == true, these functions are disabled (use off-chain ranking)
    // -----------------------------
    function _computeTopCollectionsByPercent(uint256 percent) internal view returns (address[] memory top, uint256 cutoffBurn) {
        require(!offChainTopComputationMode, "CAT: on-chain top computation disabled; use off-chain winners");

        uint256 total = _registeredCollections.length();
        if (total == 0) {
            address[] memory empty;
            return (empty, 0);
        }
        uint256 take = (total * percent) / 100;
        if (take == 0) take = 1;

        address[] memory cols = new address[](total);
        uint256[] memory burns = new uint256[](total);
        for (uint256 i = 0; i < total; i++) {
            address c = _registeredCollections.at(i);
            cols[i] = c;
            burns[i] = burnedCatalystByCollection[c];
        }

        // selection for top `take`
        for (uint256 i = 0; i < take; i++) {
            uint256 maxIdx = i;
            for (uint256 j = i + 1; j < total; j++) {
                if (burns[j] > burns[maxIdx]) maxIdx = j;
            }
            (burns[i], burns[maxIdx]) = (burns[maxIdx], burns[i]);
            (cols[i], cols[maxIdx]) = (cols[maxIdx], cols[i]);
        }

        top = new address[](take);
        for (uint256 k = 0; k < take; k++) top[k] = cols[k];
        cutoffBurn = burns[take - 1];
        return (top, cutoffBurn);
    }

    function getTopCollectionsByPercent(uint256 percent) external view returns (address[] memory) {
        (address[] memory top, ) = _computeTopCollectionsByPercent(percent);
        return top;
    }

    // -----------------------------
    // Distribute Top Burners Bonus
    // - winners passed from off-chain ranking
    // - checks treasury allowance before pulling funds
    // -----------------------------
    function distributeTopBurnerBonus(address[] calldata winners) external whenNotPaused nonReentrant {
        require(block.timestamp >= lastBonusDistribution + bonusDistributionInterval, "CAT: too soon");
        require(winners.length > 0, "CAT: no winners");

        uint256 treasuryBalance = cataTokenAsERC20.balanceOf(treasuryAddress);
        require(treasuryBalance > 0, "CAT: treasury empty");

        uint256 maxAllowed = (treasuryBalance * treasuryBonusCapBP) / 10000;
        require(maxAllowed > 0, "CAT: bonus cap zero");

        // check allowance to pull from treasury
        uint256 allowance = cataTokenAsERC20.allowance(treasuryAddress, address(this));
        require(allowance >= maxAllowed, "CAT: treasury allowance insufficient");

        uint256 totalWeight = 0;
        uint256 len = winners.length;
        for (uint256 i = 0; i < len; i++) {
            address w = winners[i];
            if (burnedCatalystByAddress[w] < minBurnToQualifyBonus) revert("CAT: winner min burn not met");
            uint256 userStakedTotal = 0;
            uint256 regCount = _registeredCollections.length();
            for (uint256 j = 0; j < regCount; j++) {
                address coll = _registeredCollections.at(j);
                userStakedTotal += stakePortfolioByUser[coll][w].length;
                if (userStakedTotal >= minStakedToQualifyBonus) break;
            }
            require(userStakedTotal >= minStakedToQualifyBonus, "CAT: winner min staked not met");
            totalWeight += burnedCatalystByAddress[w];
        }

        require(totalWeight > 0, "CAT: zero total weight");

        // pull funds from treasury
        cataTokenAsERC20.safeTransferFrom(treasuryAddress, address(this), maxAllowed);

        for (uint256 i = 0; i < len; i++) {
            address w = winners[i];
            uint256 share = (maxAllowed * burnedCatalystByAddress[w]) / totalWeight;
            if (share > 0) cataTokenAsERC20.safeTransfer(w, share);
        }

        lastBonusDistribution = block.timestamp;
        emit BonusDistributed(maxAllowed, len, block.timestamp);
    }

    // -----------------------------
    // Views for frontend
    // -----------------------------
    function getRegisteredCollections() external view returns (address[] memory) {
        uint256 n = _registeredCollections.length();
        address[] memory arr = new address[](n);
        for (uint256 i = 0; i < n; i++) arr[i] = _registeredCollections.at(i);
        return arr;
    }

    function getRegisteredCount() external view returns (uint256) {
        return _registeredCollections.length();
    }

    function getCollectionConfig(address collection) external view returns (CollectionConfig memory) {
        return collectionConfigs[collection];
    }

    // -----------------------------
    // Rescue (owner)
    // -----------------------------
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
    }

    function rescueERC721(address nft, uint256 tokenId, address to) external onlyOwner {
        IERC721(nft).transferFrom(address(this), to, tokenId);
    }
}
