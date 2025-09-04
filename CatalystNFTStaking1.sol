// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  CatalystNFTStaking.sol
  Full-featured Catalyst contract including:
    - Tiered collection registration with declared supply
    - Batch term/permanent staking + batch unstaking (MAX_BATCH)
    - Burn tracking by address & by collection
    - Enumerable registered collections for frontend
    - Governance (create / vote / execute) with voter eligibility (top X% collections OR burned)
    - Top 1% Burner Bonus distribution (off-chain ranking, on-chain validation + distribution)
    - Safety: ReentrancyGuard, Pausable, Ownable
    - Use off-chain indexing for leaderboards for scalability
*/

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Interface for Ownable contracts, a common pattern for contracts with a single owner
interface IOwnable {
    function owner() external view returns (address);
}

// Custom interface for IERC721 to ensure compatibility with ownerOf(0) check
interface IERC721Custom is IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address owner);
}

contract CatalystNFTStaking is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ---------- Tokens & addresses ----------
    IERC20 public immutable cataToken;
    address public treasuryAddress;

    // ---------- Parameters (governable by owner / governance) ----------
    uint256 public baseRewardRatePerDay; // CATA units per NFT per day
    uint256 public unstakeBurnFeeBP;     // basis points for unstake burn fee
    uint256 public constant MAX_BATCH = 50;

    // Tiered registration fees base (owner can adjust)
    uint256 public registrationFeeSmall;   // for declaredSupply 1 - 5,000
    uint256 public registrationFeeMedium;  // for declaredSupply 5,001 - 10,000
    uint256 public registrationFeeLarge;   // for declaredSupply > 10,000

    // Burner bonus governance parameters
    uint256 public bonusDistributionInterval; // seconds between distributions
    uint256 public lastBonusDistribution;
    uint256 public treasuryBonusCapBP; // max percent of treasury per cycle (bp)
    uint256 public minBurnToQualifyBonus; // minimum burned per address to be eligible
    uint256 public minStakedToQualifyBonus; // minimum NFTs staked to be eligible

    // Governance parameters
    uint256 public proposalDuration; // seconds
    uint256 public governanceTopCollectionsPercent; // e.g. 10 means top 10% collections by burned CATA are eligible

    // ---------- Data structures ----------
    struct StakeInfo {
        address owner;
        uint256 timestamp;
        bool permanent;
        bool staked;
    }

    struct CollectionConfig {
        bool registered;
        bool verified;
        uint256 stakedCount;
        uint256 totalBurned;        // CATA burned attributed to this collection
        uint256 declaredSupply;      // declared supply at registration time
    }

    struct Proposal {
        string title;
        string description;
        string parameter;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 startTime;
        uint256 endTime;
        bool executed;
    }

    // ---------- Storage ----------
    mapping(address => mapping(uint256 => StakeInfo)) public stakeLog; // collection -> tokenId -> StakeInfo
    mapping(address => CollectionConfig) public collectionConfigs;      // collection address -> config
    EnumerableSet.AddressSet private _registeredCollections;           // enumerable list for frontend

    // user portfolio: collection -> user -> list of tokenIds
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser;
    mapping(address => mapping(address => mapping(uint256 => uint256))) private _portfolioIndex; // index+1

    // burn tracking
    mapping(address => uint256) public burnedCatalystByAddress;
    mapping(address => uint256) public burnedCatalystByCollection;
    uint256 public totalBurnedCATA;

    // governance
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    uint256 public proposalCount;

    // protocol totals
    uint256 public totalStakedNFTsCount;
    uint256 public totalStakersCount;

    // ---------- Events ----------
    event CollectionRegistered(address indexed collection, address indexed registrar, uint256 feePaid, uint256 declaredSupply, bool verifiedStatus);
    event Stake(address indexed user, address indexed collection, uint256 indexed tokenId, bool permanent);
    event Unstake(address indexed user, address indexed collection, uint256 indexed tokenId);
    event BatchStake(address indexed user, address indexed collection, uint256 count, bool permanent);
    event BatchUnstake(address indexed user, address indexed collection, uint256 count);
    event Burned(address indexed user, uint256 amount, address indexed collection);
    event ProposalCreated(uint256 indexed id, string title, uint256 startTime, uint256 endTime);
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed id, bool passed);
    event BonusDistributed(uint256 totalAmount, uint256 winnersCount, uint256 timestamp);

    // ---------- Constructor ----------
    constructor(
        address _cataToken,
        address _treasury,
        uint256 _baseRewardRatePerDay,
        uint256 _unstakeBurnFeeBP,
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
        require(_cataToken != address(0), "zero CATA");
        require(_treasury != address(0), "zero treasury");
        require(_unstakeBurnFeeBP <= 10000, "bad bp");
        require(_treasuryBonusCapBP <= 10000, "bad treasury cap bp");

        cataToken = IERC20(_cataToken);
        treasuryAddress = _treasury;

        baseRewardRatePerDay = _baseRewardRatePerDay;
        unstakeBurnFeeBP = _unstakeBurnFeeBP;

        registrationFeeSmall = _registrationFeeSmall;
        registrationFeeMedium = _registrationFeeMedium;
        registrationFeeLarge = _registrationFeeLarge;

        bonusDistributionInterval = _bonusDistributionInterval;
        treasuryBonusCapBP = _treasuryBonusCapBP;
        minBurnToQualifyBonus = _minBurnToQualifyBonus;
        minStakedToQualifyBonus = _minStakedToQualifyBonus;
        lastBonusDistribution = 0;

        proposalDuration = _proposalDuration;
        governanceTopCollectionsPercent = _governanceTopCollectionsPercent;

        // Ownable will set owner = msg.sender automatically
    }

    // ---------- Modifiers ----------
    modifier onlyRegistered(address collection) {
        require(collectionConfigs[collection].registered, "collection not registered");
        _;
    }

    // ---------- Admin setters (owner / governance can later be set to multisig) ----------
    function setTreasury(address _treasury) external onlyOwner { require(_treasury != address(0)); treasuryAddress = _treasury; }
    function setBaseRewardRatePerDay(uint256 v) external onlyOwner { baseRewardRatePerDay = v; }
    function setUnstakeBurnFeeBP(uint256 bp) external onlyOwner { require(bp <= 10000); unstakeBurnFeeBP = bp; }
    function setRegistrationFees(uint256 smallFee, uint256 medFee, uint256 largeFee) external onlyOwner {
        registrationFeeSmall = smallFee; registrationFeeMedium = medFee; registrationFeeLarge = largeFee;
    }
    function setBonusSettings(uint256 interval, uint256 capBP, uint256 minBurn, uint256 minStaked) external onlyOwner {
        bonusDistributionInterval = interval; treasuryBonusCapBP = capBP;
        minBurnToQualifyBonus = minBurn; minStakedToQualifyBonus = minStaked;
    }
    function setProposalDuration(uint256 secs) external onlyOwner { proposalDuration = secs; }
    function setGovernanceTopCollectionsPercent(uint256 p) external onlyOwner { governanceTopCollectionsPercent = p; }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ---------- Utilities ----------
    function _doBurn(address user, uint256 amount, address collection) internal {
        require(amount > 0, "zero burn");
        address dead = address(0x000000000000000000000000000000000000dEaD);

        // burn tokens already held by this contract
        // NOTE: caller must have transferred tokens into this contract prior to calling _doBurn
        cataToken.safeTransfer(dead, amount);

        burnedCatalystByAddress[user] += amount;
        if (collection != address(0)) {
            burnedCatalystByCollection[collection] += amount;
            collectionConfigs[collection].totalBurned += amount;
        }
        totalBurnedCATA += amount;
        emit Burned(user, amount, collection);
    }

    // ---------- Collection Registration (tiered, updated rules) ----------
    function registerCollection(address collection, uint256 declaredSupply, bool verified) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        require(collection != address(0), "zero collection");
        require(!collectionConfigs[collection].registered, "already registered");

        // Determine if caller is contract owner (admin)
        bool isAdmin = msg.sender == owner();
        bool isCollectionOwner = false;

        // Check collection owner using ERC721 ownerOf(0)
        try IERC721Custom(collection).ownerOf(0) returns (address ownerAddr) {
            if (ownerAddr == msg.sender) {
                isCollectionOwner = true;
            }
        } catch {
            // Fallback to Ownable.owner() if supported
            try IOwnable(collection).owner() returns (address contractOwner) {
                if (contractOwner == msg.sender) {
                    isCollectionOwner = true;
                }
            } catch {
                isCollectionOwner = false;
            }
        }

        // Tier rules:
        // - Contract Owner or Collection Owner can set `verified` status
        // - All others are forced to UNVERIFIED
        if (!isAdmin && !isCollectionOwner) {
            verified = false;
        }

        uint256 fee = _registrationFeeBySupply(declaredSupply);
        // pull fee
        cataToken.safeTransferFrom(msg.sender, address(this), fee);

        // burn 90%, treasury 10%
        uint256 burnAmt = (fee * 90) / 100;
        uint256 treasuryAmt = fee - burnAmt;

        // burn: transfer burnAmt to dead from contract
        _doBurn(msg.sender, burnAmt, collection);
        // treasury transfer
        cataToken.safeTransfer(treasuryAddress, treasuryAmt);

        // register
        collectionConfigs[collection] = CollectionConfig({
            registered: true,
            verified: verified,
            stakedCount: 0,
            totalBurned: burnAmt,
            declaredSupply: declaredSupply
        });
        _registeredCollections.add(collection);

        emit CollectionRegistered(collection, msg.sender, fee, declaredSupply, verified);
    }

    function _registrationFeeBySupply(uint256 declaredSupply) internal view returns (uint256) {
        if (declaredSupply == 0) {
            // if unknown, treat as large
            return registrationFeeLarge;
        } else if (declaredSupply <= 5000) {
            return registrationFeeSmall;
        } else if (declaredSupply <= 10000) {
            return registrationFeeMedium;
        } else {
            return registrationFeeLarge;
        }
    }

    // ---------- Staking (single & batch) ----------
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
        require(len > 0 && len <= MAX_BATCH, "invalid batch");
        for (uint256 i = 0; i < len; i++) {
            _stake(collection, tokenIds[i], permanent);
        }
        emit BatchStake(msg.sender, collection, len, permanent);
    }

    function _stake(address collection, uint256 tokenId, bool permanent) internal {
        IERC721 nft = IERC721(collection);
        require(nft.ownerOf(tokenId) == msg.sender, "not owner");

        // transfer NFT to contract
        nft.transferFrom(msg.sender, address(this), tokenId);

        // record stake
        stakeLog[collection][tokenId] = StakeInfo({
            owner: msg.sender,
            timestamp: block.timestamp,
            permanent: permanent,
            staked: true
        });

        // add to portfolio
        _portfolioIndex[collection][msg.sender][tokenId] = stakePortfolioByUser[collection][msg.sender].length + 1;
        stakePortfolioByUser[collection][msg.sender].push(tokenId);

        // totals
        totalStakedNFTsCount++;
        collectionConfigs[collection].stakedCount++;
        totalStakersCount++; // simplistic; counting may double-count across multiple stakes by same user

        emit Stake(msg.sender, collection, tokenId, permanent);
    }

    // ---------- Unstake (single & batch) ----------
    function unstake(address collection, uint256 tokenId) public whenNotPaused nonReentrant {
        StakeInfo storage s = stakeLog[collection][tokenId];
        require(s.staked, "not staked");
        require(s.owner == msg.sender, "not staker");

        // return NFT
        IERC721(collection).transferFrom(address(this), msg.sender, tokenId);

        // mark unstaked
        s.staked = false;

        // burn unstake fee (we withdraw fee from user: require allowance)
        uint256 fee = (baseRewardRatePerDay * unstakeBurnFeeBP) / 10000; // simple fee; adjust formula if needed
        if (fee > 0) {
            // pull fee
            cataToken.safeTransferFrom(msg.sender, address(this), fee);
            _doBurn(msg.sender, fee, collection);
        }

        // remove from portfolio
        _removeFromPortfolio(collection, msg.sender, tokenId);

        if (totalStakedNFTsCount > 0) totalStakedNFTsCount--;
        if (collectionConfigs[collection].stakedCount > 0) collectionConfigs[collection].stakedCount--;
        emit Unstake(msg.sender, collection, tokenId);
    }

    function unstakeBatch(address collection, uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        uint256 len = tokenIds.length;
        require(len > 0 && len <= MAX_BATCH, "invalid batch");
        for (uint256 i = 0; i < len; i++) {
            unstake(collection, tokenIds[i]);
        }
        emit BatchUnstake(msg.sender, collection, len);
    }

    // ---------- Portfolio helpers ----------
    function _removeFromPortfolio(address collection, address user, uint256 tokenId) internal {
        uint256 idxPlusOne = _portfolioIndex[collection][user][tokenId];
        require(idxPlusOne != 0, "not in portfolio");
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

    // ---------- Burning (public) ----------
    // User burns CATA and optionally attributes to a collection (for collection rankings)
    function burnCATA(uint256 amount, address collection) external whenNotPaused nonReentrant {
        require(amount > 0, "zero");
        cataToken.safeTransferFrom(msg.sender, address(this), amount);
        _doBurn(msg.sender, amount, collection);
    }

    // ---------- Governance ----------
    function createProposal(string calldata title, string calldata description, string calldata parameter) external whenNotPaused {
        proposals[proposalCount] = Proposal({
            title: title,
            description: description,
            parameter: parameter,
            votesFor: 0,
            votesAgainst: 0,
            startTime: block.timestamp,
            endTime: block.timestamp + proposalDuration,
            executed: false
        });
        emit ProposalCreated(proposalCount, title, block.timestamp, block.timestamp + proposalDuration);
        proposalCount++;
    }

    // voter eligibility rules:
    // - either burnedCatalystByAddress[voter] >= minBurnThresholdForVote OR
    // - voter has staked NFTs in collections that are in the top X% by burnedCatalystByCollection
    uint256 public minBurnThresholdForVote = 1 ether;
    function setMinBurnThresholdForVote(uint256 v) external onlyOwner { minBurnThresholdForVote = v; }

    // helper: compute whether address is eligible to vote
    function isVoterEligible(address voter) public view returns (bool) {
        if (burnedCatalystByAddress[voter] >= minBurnThresholdForVote) return true;

        // check if voter stakes any NFTs in eligible collections
        (address[] memory topCollections, ) = _computeTopCollectionsByPercent(governanceTopCollectionsPercent);
        if (topCollections.length == 0) return false;
        for (uint256 i = 0; i < topCollections.length; i++) {
            if (stakePortfolioByUser[topCollections[i]][voter].length > 0) return true;
        }
        return false;
    }

    function voteOnProposal(uint256 id, bool support) external whenNotPaused nonReentrant {
        require(id < proposalCount, "invalid id");
        Proposal storage p = proposals[id];
        require(block.timestamp >= p.startTime && block.timestamp < p.endTime, "voting closed");
        require(!hasVoted[id][msg.sender], "already voted");
        require(isVoterEligible(msg.sender), "not eligible to vote");

        uint256 weight = burnedCatalystByAddress[msg.sender];
        require(weight > 0, "no voting weight");

        if (support) p.votesFor += weight; else p.votesAgainst += weight;
        hasVoted[id][msg.sender] = true;
        emit Voted(id, msg.sender, support, weight);
    }

    function executeProposal(uint256 id, uint256 minVotesForExecution) external whenNotPaused nonReentrant {
        // minVotesForExecution is the minimum total votesFor required, can be checked by caller/off-chain
        require(id < proposalCount, "invalid id");
        Proposal storage p = proposals[id];
        require(block.timestamp >= p.endTime, "not ended");
        require(!p.executed, "already executed");

        bool passed = (p.votesFor > p.votesAgainst) && (p.votesFor >= minVotesForExecution);
        p.executed = true;
        emit ProposalExecuted(id, passed);
        // note: actual execution of parameters must be implemented via owner-controlled functions or a timelock
    }

    // ---------- Top Collections helpers (on-chain compute) ----------
    // returns top N percent of registered collections by burnedCatalystByCollection
    // NOTE: O(n^2) selection algorithm — fine for moderate number of collections (hundreds). For large systems, compute off-chain.
    function _computeTopCollectionsByPercent(uint256 percent) internal view returns (address[] memory top, uint256 cutoffBurn) {
        uint256 total = _registeredCollections.length();
        if (total == 0) {
            address[] memory empty;
            return (empty, 0);
        }
        uint256 take = (total * percent) / 100;
        if (take == 0) take = 1;

        // gather pairs
        address[] memory cols = new address[](total);
        uint256[] memory burns = new uint256[](total);
        for (uint256 i = 0; i < total; i++) {
            address c = _registeredCollections.at(i);
            cols[i] = c;
            burns[i] = burnedCatalystByCollection[c];
        }

        // simple selection sort for top `take`
        for (uint256 i = 0; i < take; i++) {
            uint256 maxIdx = i;
            for (uint256 j = i + 1; j < total; j++) {
                if (burns[j] > burns[maxIdx]) maxIdx = j;
            }
            // swap i and maxIdx
            (burns[i], burns[maxIdx]) = (burns[maxIdx], burns[i]);
            (cols[i], cols[maxIdx]) = (cols[maxIdx], cols[i]);
        }

        // prepare result array
        top = new address[](take);
        for (uint256 k = 0; k < take; k++) top[k] = cols[k];
        cutoffBurn = burns[take - 1];
        return (top, cutoffBurn);
    }

    function getTopCollectionsByPercent(uint256 percent) external view returns (address[] memory) {
        (address[] memory top, ) = _computeTopCollectionsByPercent(percent);
        return top;
    }

    // ---------- Top 1% Burner Bonus Distribution (governance-controlled) ----------
    // off-chain: compute winners (top 1% wallets by burnedCatalystByAddress), pass as `winners`
    // This function validates each winner meets min participation thresholds and distributes proportionally
    function distributeTopBurnerBonus(address[] calldata winners) external whenNotPaused nonReentrant {
        require(block.timestamp >= lastBonusDistribution + bonusDistributionInterval, "too soon");
        require(winners.length > 0, "no winners");

        // compute treasury available (CATA balance in treasury)
        uint256 treasuryBalance = IERC20(cataToken).balanceOf(treasuryAddress);
        require(treasuryBalance > 0, "treasury empty");

        // compute max allowed
        uint256 maxAllowed = (treasuryBalance * treasuryBonusCapBP) / 10000;
        require(maxAllowed > 0, "bonus cap zero");

        // Verify winners meet thresholds and compute total weight
        uint256 totalWeight = 0;
        uint256 len = winners.length;
        for (uint256 i = 0; i < len; i++) {
            address w = winners[i];
            // check burned minimum
            if (burnedCatalystByAddress[w] < minBurnToQualifyBonus) revert("winner min burn not met");
            // check staked minimum
            uint256 userStakedTotal = 0;
            uint256 regCount = _registeredCollections.length();
            for (uint256 j = 0; j < regCount; j++) {
                address coll = _registeredCollections.at(j);
                userStakedTotal += stakePortfolioByUser[coll][w].length;
                if (userStakedTotal >= minStakedToQualifyBonus) break;
            }
            require(userStakedTotal >= minStakedToQualifyBonus, "winner min staked not met");
            totalWeight += burnedCatalystByAddress[w];
        }

        require(totalWeight > 0, "zero total weight");

        // To distribute, the treasury must have approved this contract to transfer tokens.
        IERC20(cataToken).safeTransferFrom(treasuryAddress, address(this), maxAllowed);

        // distribute proportional
        for (uint256 i = 0; i < len; i++) {
            address w = winners[i];
            uint256 share = (maxAllowed * burnedCatalystByAddress[w]) / totalWeight;
            if (share > 0) {
                cataToken.safeTransfer(w, share);
            }
        }

        lastBonusDistribution = block.timestamp;
        emit BonusDistributed(maxAllowed, len, block.timestamp);
    }

    // ---------- Rewards view ----------
    function pendingRewards(address collection, uint256 tokenId) external view returns (uint256) {
        StakeInfo memory s = stakeLog[collection][tokenId];
        if (!s.staked) return 0;
        uint256 duration = block.timestamp - s.timestamp;
        return (baseRewardRatePerDay * duration) / 1 days;
    }

    // ---------- Helper getters for front-end ----------
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

    // ---------- Rescue ----------
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
    }
    function rescueERC721(address nft, uint256 tokenId, address to) external onlyOwner {
        IERC721(nft).transferFrom(address(this), to, tokenId);
    }
}
