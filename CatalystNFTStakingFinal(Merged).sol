// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
Catalyst NFT Staking — Final (Merged)

This contract merges:
- ERC20 (CATA) + NFT staking + internal treasury vault
- Permissionless collection registration (registerCollection)
- Immutable 90/9/1 fee split (burn / treasury / deployer)
- Surcharge escrow for UNVERIFIED collections (refund / forfeit)
- Full staking (term & permanent), batch stake/unstake, harvest, governance, burner bookkeeping,
  top-collections maintenance, top-burner bonus distribution, admin controls, pause/rescue, etc.

NOTES:
- This is a large contract intended as a single-file deployment source.
- Review, test thoroughly on testnet, and run a full security audit before mainnet use.
- The contract assumes CATA is the ERC20 token represented by this ERC20 contract (the contract is its own token).
*/

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC721/IERC721Receiver.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC721/IERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/security/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC20/IERC20.sol";

interface IOwnable {
    function owner() external view returns (address);
}

contract CatalystNFTStaking is ERC20, AccessControl, IERC721Receiver, ReentrancyGuard, Pausable {
    // ---------- Roles ----------
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // ---------- Immutable Fee Split (basis points) ----------
    uint256 public constant BURN_BP = 9000;    // 90.00%
    uint256 public constant TREASURY_BP = 900; // 9.00%
    uint256 public constant DEPLOYER_BP = 100; // 1.00%

   // ---------- Internal Treasury Vault ----------
    uint256 public treasuryBalance; // tracks total treasury funds held by this contract

    // ---------- Constants ----------
    uint256 public constant WEIGHT_SCALE = 1e18;
    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public constant MAX_STAKE_PER_COLLECTION = 20000; // per spec

    // ---------- Enums ----------
    enum CollectionTier { UNVERIFIED, VERIFIED }
    enum ProposalType {
        BASE_REWARD,
        HARVEST_FEE,
        UNSTAKE_FEE,
        REGISTRATION_FEE_FALLBACK,
        VOTING_PARAM,
        TIER_UPGRADE
    }

    // ---------- Structs ----------
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

    struct CollectionConfig {
        uint256 totalStaked;
        uint256 totalStakers;
        bool registered;
        uint256 declaredSupply;
    }

    struct StakeInfo {
        uint256 stakeBlock;
        uint256 lastHarvestBlock;
        bool currentlyStaked;
        bool isPermanent;
        uint256 unstakeDeadlineBlock;
    }

    struct CollectionMeta {
        CollectionTier tier;
        address registrant;
        uint256 surchargeEscrow;
        uint256 registeredAtBlock;
        uint256 lastTierProposalBlock;
    }

    // ---------- Storage: collections & staking ----------
    mapping(address => CollectionConfig) public collectionConfigs;
    mapping(address => CollectionMeta) public collectionMeta;
    mapping(address => mapping(address => mapping(uint256 => StakeInfo))) public stakeLog; // collection => user => tokenId => info
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser;          // collection => user => tokenIds
    mapping(address => mapping(uint256 => uint256)) public indexOfTokenIdInStakePortfolio;  // collection => tokenId => index
    mapping(address => uint256) public burnedCatalystByCollection;                          // collection => total burned via contract flows

    // ---------- Proposals & voting ----------
    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => mapping(address => uint256)) public proposalCollectionVotesScaled;   // cap votes per collection (anti-collusion)

    // ---------- Registered collections enumeration ----------
    address[] public registeredCollections;
    mapping(address => uint256) public registeredIndex; // 1-based index; 0 => not registered

    // ---------- Tokenomics params ----------
    uint256 public numberOfBlocksPerRewardUnit = 18782; // ~1 day on some chains (adjust via governance)
    uint256 public collectionRegistrationFee;           // fallback/base fee (governance adjustable)
    uint256 public unstakeBurnFee;                      // flat burn fee in CATA when unstaking (in token units)
    address public treasuryAddress;
    uint256 public totalStakedNFTsCount;                // global NFT count staked
    uint256 public baseRewardRate;                      // global emission base (rises with more stakes)
    uint256 public initialHarvestBurnFeeRate;           // % of harvest burned (0..100)
    uint256 public termDurationBlocks;                  // term length for term stakes
    uint256 public stakingCooldownBlocks;               // per-wallet cooldown between stakes
    uint256 public harvestRateAdjustmentFactor;         // if >0: fee = initialHarvestBurnFeeRate + baseRewardRate / factor
    uint256 public minBurnContributionForVote;          // min collection burn to allow context-weighted voting

    uint256 public initialCollectionFee;                // for permanent stake fee curve base
    uint256 public feeMultiplier;                       // for sqrt(totalStaked) * feeMultiplier component
    uint256 public rewardRateIncrementPerNFT;           // how much baseRewardRate increases per new stake
    uint256 public welcomeBonusBaseRate;                // mint on stake
    uint256 public welcomeBonusIncrementPerNFT;         // additional mint per global staked count

    // ---------- Registration fee brackets ----------
    uint256 public SMALL_MIN_FEE = 1000 * 10**18;
    uint256 public SMALL_MAX_FEE = 5000 * 10**18;
    uint256 public MED_MIN_FEE   = 5000 * 10**18;
    uint256 public MED_MAX_FEE   = 10000 * 10**18;
    uint256 public LARGE_MIN_FEE = 10000 * 10**18;
    uint256 public LARGE_MAX_FEE_CAP = 20000 * 10**18;

    // Unverified surcharge multiplier in basis points (10000 = 1x)
    uint256 public unverifiedSurchargeBP = 20000; // default 2x total (10000 -> 1x; 20000 -> 2x)

    // Tier upgrade thresholds & timings
    uint256 public tierUpgradeMinAgeBlocks = 200000;
    uint256 public tierUpgradeMinBurn = 50_000 * 10**18;
    uint256 public tierUpgradeMinStakers = 50;
    uint256 public tierProposalCooldownBlocks = 30000;
    uint256 public surchargeForfeitBlocks = 600000; // after this, escrow can be split (burn/treasury)

    // ---------- Governance / leaderboards ----------
    address[] public topCollections; // sorted desc by burnedCatalystByCollection
    uint256 public topPercent = 10; // top X% collections are eligible for full voting weight
    uint256 public minVotesRequiredScaled = 3 * WEIGHT_SCALE; // quorum
    uint256 public votingDurationBlocks = 46000; // ~1 week-ish
    uint256 public smallCollectionVoteWeightScaled = (WEIGHT_SCALE * 50) / 100; // 0.5x for non-top/context collections
    uint256 public maxBaseRewardRate = type(uint256).max; // cap new baseRewardRate via governance

    // anti-collusion & stake-age
    uint256 public collectionVoteCapPercent = 70; // % of quorum allowed from a single collection
    uint256 public minStakeAgeForVoting = 100;    // min blocks since staking to vote/propose

    // ---------- Burner bonus system ----------
    address[] public participatingWallets; // addresses that burned at least once via contract flows
    mapping(address => bool) public isParticipating;
    mapping(address => uint256) public burnedCatalystByAddress; // total burned by address via contract flows
    mapping(address => uint256) public lastBurnBlock; // last block user burned via contract

    address[] public topBurners; // admin-built ranking for the current cycle
    uint256 public bonusCycleLengthBlocks = 65000; // how often bonuses can be distributed
    uint256 public lastBonusCycleBlock = 0;
    uint256 public bonusPoolPercentPerCycleBP = 500; // 5% of treasury per cycle
    uint256 public minBurnForRanking = 100 * 10**18; // filter for ranking
    uint256 public minStakedNFTsForBonus = 1;        // alt eligibility: stake >= N NFTs
    uint256 public minBurnToEnterTopPercent = 10 * 10**18; // min burn to be in top-percent calc

    // governance / deployer
    address public immutable deployerAddress;

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
    event EscrowForfeited(address indexed collection, uint256 amountToTreasury, uint256 amountBurned);

    event TopBurnersRebuilt(address indexed admin, uint256 count);
    event BurnerBonusDistributed(uint256 cycleStartBlock, uint256 poolAmount, uint256 recipientsCount);

    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    

    event BaseRewardRateUpdated(uint256 oldValue, uint256 newValue);
    event HarvestFeeUpdated(uint256 oldValue, uint256 newValue);
    event UnstakeFeeUpdated(uint256 oldValue, uint256 newValue);
    event RegistrationFeeUpdated(uint256 oldValue, uint256 newValue);
    event VotingParamUpdated(uint8 target, uint256 oldValue, uint256 newValue);

    // Treasury events
    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);

  // ---------- Constructor Config Struct ----------
struct InitConfig {
    address owner;
    address treasury;
    uint256 initialCollectionFee;
    uint256 feeMultiplier;
    uint256 rewardRateIncrementPerNFT;
    uint256 welcomeBonusBaseRate;
    uint256 welcomeBonusIncrementPerNFT;
    uint256 initialHarvestBurnFeeRate;
    uint256 termDurationBlocks;
    uint256 collectionRegistrationFeeFallback;
    uint256 unstakeBurnFee;
    uint256 stakingCooldownBlocks;
    uint256 harvestRateAdjustmentFactor;
    uint256 minBurnContributionForVote;
}

constructor(InitConfig memory cfg) ERC20("Catalyst", "CATA") {
    require(cfg.owner != address(0) && cfg.treasury != address(0), "CATA: bad addr");

    _mint(cfg.owner, 25_185_000 * 10**18);

    _grantRole(DEFAULT_ADMIN_ROLE, cfg.owner);
    _grantRole(CONTRACT_ADMIN_ROLE, cfg.owner);

    treasuryAddress = address(this);
    deployerAddress = cfg.owner;

    initialCollectionFee = cfg.initialCollectionFee;
    feeMultiplier = cfg.feeMultiplier;
    rewardRateIncrementPerNFT = cfg.rewardRateIncrementPerNFT;
    welcomeBonusBaseRate = cfg.welcomeBonusBaseRate;
    welcomeBonusIncrementPerNFT = cfg.welcomeBonusIncrementPerNFT;
    initialHarvestBurnFeeRate = cfg.initialHarvestBurnFeeRate;
    termDurationBlocks = cfg.termDurationBlocks;
    collectionRegistrationFee = cfg.collectionRegistrationFeeFallback;
    unstakeBurnFee = cfg.unstakeBurnFee;
    stakingCooldownBlocks = cfg.stakingCooldownBlocks;
    harvestRateAdjustmentFactor = cfg.harvestRateAdjustmentFactor;
    minBurnContributionForVote = cfg.minBurnContributionForVote;
}
    
    // ---------- Modifiers ----------
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: cooldown");
        _;
    }

    mapping(address => uint256) public lastStakingBlock; // wallet => last stake block

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
        uint256 multBP = (tier == CollectionTier.UNVERIFIED) ? unverifiedSurchargeBP : 10000;
        uint256 total = (baseFee * multBP) / 10000;
        feeToPay = total;
        surchargeAmount = (multBP > 10000) ? (total - baseFee) : 0;
    }

    // helper to compute fee & surcharge for prospective registration (collectionMeta not yet set)
    function _computeFeeAndSurchargeForTier(uint256 baseFee, CollectionTier tier) internal view returns (uint256 totalFee, uint256 surcharge) {
        uint256 multBP = (tier == CollectionTier.UNVERIFIED) ? unverifiedSurchargeBP : 10000;
        uint256 total = (baseFee * multBP) / 10000;
        uint256 sur = (multBP > 10000) ? (total - baseFee) : 0;
        return (total, sur);
    }

    // ---------- Immutable split helper (burn from payer + transfers) ----------
    function _splitFeeFromSender(address payer, uint256 amount, address collection, bool attributeToUser) internal {
        require(amount > 0, "CATA: zero fee");

        uint256 burnAmt = (amount * BURN_BP) / 10000;
        uint256 treasuryAmt = (amount * TREASURY_BP) / 10000;
        uint256 deployerAmt = amount - burnAmt - treasuryAmt; // DEPLOYER_BP portion

        // burn from payer
        if (burnAmt > 0) {
            _burn(payer, burnAmt);
            burnedCatalystByCollection[collection] += burnAmt;
            if (attributeToUser) {
                burnedCatalystByAddress[payer] += burnAmt;
                lastBurnBlock[payer] = block.number;
                if (!isParticipating[payer]) { isParticipating[payer] = true; participatingWallets.push(payer); }
            }
        }

        // transfer deployer share
        if (deployerAmt > 0) {
            _transfer(payer, deployerAddress, deployerAmt);
        }

        // transfer treasury share INTO contract and account for it in the internal vault
        if (treasuryAmt > 0) {
            _transfer(payer, address(this), treasuryAmt);
            treasuryBalance += treasuryAmt;
            emit TreasuryDeposit(payer, treasuryAmt);
        }
    }

    // ---------- Collection registration (admin-only kept) ----------
    function setCollectionConfig(address collection, uint256 declaredMaxSupply, CollectionTier tier) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(collection != address(0), "CATA: bad addr");
        require(!_isRegistered(collection), "CATA: already reg");
        require(declaredMaxSupply >= 1 && declaredMaxSupply <= MAX_STAKE_PER_COLLECTION, "CATA: supply range");

        uint256 baseFee = _calculateRegistrationBaseFee(declaredMaxSupply);
        (uint256 totalFee, uint256 surcharge) = _computeFeeAndSurchargeForTier(baseFee, tier);
        require(balanceOf(_msgSender()) >= totalFee, "CATA: insufficient CATA");

        // burn/transfer base fee
        _splitFeeFromSender(_msgSender(), baseFee, collection, true);

        uint256 escrowAmt = 0;
        if (surcharge > 0) {
            // escrow surcharge into contract
            _transfer(_msgSender(), address(this), surcharge);
            escrowAmt = surcharge;
        }

        // register enumerations
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

        _updateTopCollectionsOnBurn(collection);
        _maybeRebuildTopCollections();

        emit CollectionAdded(collection, declaredMaxSupply, baseFee, escrowAmt, tier);
    }

    // ---------- NEW: Public registerCollection (permissionless) ----------
    function registerCollection(address collection, uint256 declaredMaxSupply, CollectionTier requestedTier) external nonReentrant whenNotPaused {
        require(collection != address(0), "CATA: bad addr");
        require(!_isRegistered(collection), "CATA: already reg");
        require(declaredMaxSupply >= 1 && declaredMaxSupply <= MAX_STAKE_PER_COLLECTION, "CATA: supply range");

        // Determine if caller can legitimately request VERIFIED
        bool allowVerified = false;
        // admin may request verified
        if (hasRole(CONTRACT_ADMIN_ROLE, _msgSender()) || hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            allowVerified = true;
        } else {
            // attempt to detect collection owner: try ownerOf(0) then IOwnable
            try IERC721(collection).ownerOf(0) returns (address ownerAddr) {
                if (ownerAddr == _msgSender()) allowVerified = true;
            } catch {
                // try Ownable pattern
                try IOwnable(collection).owner() returns (address contractOwner) {
                    if (contractOwner == _msgSender()) allowVerified = true;
                } catch {
                    allowVerified = false;
                }
            }
        }

        CollectionTier tierToUse = requestedTier;
        if (!allowVerified && requestedTier == CollectionTier.VERIFIED) {
            // can't set verified if not admin or collection owner
            tierToUse = CollectionTier.UNVERIFIED;
        }

        uint256 baseFee = _calculateRegistrationBaseFee(declaredMaxSupply);
        (uint256 totalFee, uint256 surcharge) = _computeFeeAndSurchargeForTier(baseFee, tierToUse);

        // require the caller has enough token balance to cover the *total* (baseFee + surcharge)
        require(balanceOf(_msgSender()) >= totalFee, "CATA: insufficient balance for fee");

        // burn/transfer baseFee via immutable split
        _splitFeeFromSender(_msgSender(), baseFee, collection, true);

        uint256 escrowAmt = 0;
        if (surcharge > 0) {
            // move surcharge portion to contract as escrow (transfer from payer to contract)
            _transfer(_msgSender(), address(this), surcharge);
            escrowAmt = surcharge;
        }

        // register enumerations
        registeredCollections.push(collection);
        registeredIndex[collection] = registeredCollections.length;

        collectionConfigs[collection] = CollectionConfig({
            totalStaked: 0,
            totalStakers: 0,
            registered: true,
            declaredSupply: declaredMaxSupply
        });

        collectionMeta[collection] = CollectionMeta({
            tier: tierToUse,
            registrant: _msgSender(),
            surchargeEscrow: escrowAmt,
            registeredAtBlock: block.number,
            lastTierProposalBlock: 0
        });

        _updateTopCollectionsOnBurn(collection);
        _maybeRebuildTopCollections();

        emit CollectionAdded(collection, declaredMaxSupply, baseFee, escrowAmt, tierToUse);
    }

    // ---------- removeCollection ----------
    function removeCollection(address collection) external onlyRole(CONTRACT_ADMIN_ROLE) whenNotPaused {
        require(collectionConfigs[collection].registered, "CATA: not reg");
        collectionConfigs[collection].registered = false;

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

        // remove from topCollections if present
        for (uint256 t = 0; t < topCollections.length; t++) {
            if (topCollections[t] == collection) {
                for (uint256 j = t; j + 1 < topCollections.length; j++) topCollections[j] = topCollections[j + 1];
                topCollections.pop();
                break;
            }
        }

        emit CollectionRemoved(collection);
    }

    // ---------- Tier upgrade eligibility & escrow forfeit ----------
    function _eligibleForTierUpgrade(address collection) internal view returns (bool) {
        CollectionMeta memory m = collectionMeta[collection];
        if (m.tier != CollectionTier.UNVERIFIED) return false;
        if (block.number < m.registeredAtBlock + tierUpgradeMinAgeBlocks) return false;
        if (burnedCatalystByCollection[collection] < tierUpgradeMinBurn) return false;
        if (collectionConfigs[collection].totalStakers < tierUpgradeMinStakers) return false;
        return true;
    }

    function forfeitEscrowIfExpired(address collection) external onlyRole(CONTRACT_ADMIN_ROLE) {
        CollectionMeta storage m = collectionMeta[collection];
        require(collectionConfigs[collection].registered, "CATA: not reg");
        require(m.tier == CollectionTier.UNVERIFIED, "CATA: already verified");
        require(block.number >= m.registeredAtBlock + surchargeForfeitBlocks, "CATA: not expired");
        uint256 amt = m.surchargeEscrow;
        require(amt > 0, "CATA: no escrow");

        uint256 toBurn = amt / 2;
        uint256 toTreasury = amt - toBurn;
        _burn(address(this), toBurn);
        // escrow already in contract; move to internal treasury accounting (no external transfer)
        treasuryBalance += toTreasury;
        emit TreasuryDeposit(address(this), toTreasury);
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

        // use immutable split: burn 90% from payer, transfer 9% to treasury and 1% to deployer
        _splitFeeFromSender(_msgSender(), fee, collection, true);

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

        uint256 dynamicWelcome = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
        _mint(_msgSender(), dynamicWelcome);

        lastStakingBlock[_msgSender()] = block.number;
        emit PermanentStakeFeePaid(_msgSender(), fee);
        emit NFTStaked(_msgSender(), collection, tokenId);
    }

    // Batch staking helpers (sequential)
    function batchTermStake(address collection, uint256[] calldata tokenIds) external {
        require(tokenIds.length > 0 && tokenIds.length <= MAX_HARVEST_BATCH, "CATA: batch");
        for (uint256 i = 0; i < tokenIds.length; i++) termStake(collection, tokenIds[i]);
    }
    function batchPermanentStake(address collection, uint256[] calldata tokenIds) external {
        require(tokenIds.length > 0 && tokenIds.length <= MAX_HARVEST_BATCH, "CATA: batch");
        for (uint256 i = 0; i < tokenIds.length; i++) permanentStake(collection, tokenIds[i]);
    }

    function unstake(address collection, uint256 tokenId) public nonReentrant whenNotPaused {
        StakeInfo storage info = stakeLog[collection][_msgSender()][tokenId];
        require(info.currentlyStaked, "CATA: not staked");
        if (!info.isPermanent) require(block.number >= info.unstakeDeadlineBlock, "CATA: term active");

        _harvest(collection, _msgSender(), tokenId);
        require(balanceOf(_msgSender()) >= unstakeBurnFee, "CATA: fee");
        // collect fee from payer and split immutably
        _splitFeeFromSender(_msgSender(), unstakeBurnFee, collection, true);

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

    function batchUnstake(address collection, uint256[] calldata tokenIds) external {
        uint256 len = tokenIds.length;
        require(len > 0 && len <= MAX_HARVEST_BATCH, "CATA: batch");
        for (uint256 i = 0; i < len; i++) {
            unstake(collection, tokenIds[i]);
        }
    }

    // ---------- Harvest ----------
    function _harvest(address collection, address user, uint256 tokenId) internal {
        StakeInfo storage info = stakeLog[collection][user][tokenId];
        uint256 reward = pendingRewards(collection, user, tokenId);
        if (reward == 0) return;

        uint256 feeRate = _getDynamicHarvestBurnFeeRate();
        uint256 burnAmt = (reward * feeRate) / 100;
        uint256 payout = reward - burnAmt;

        // mint reward to user (contract is ERC20 CATA itself)
        _mint(user, reward);

        if (burnAmt > 0) {
            _burn(user, burnAmt);
            burnedCatalystByCollection[collection] += burnAmt;
            // protocol-attributed (not credited to user)
            lastBurnBlock[user] = block.number;
            burnedCatalystByAddress[user] += burnAmt; // still track for participation
            _updateTopCollectionsOnBurn(collection);
        }
        info.lastHarvestBlock = block.number;

        emit RewardsHarvested(user, collection, payout, burnAmt);
    }

    function harvestBatch(address collection, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0 && tokenIds.length <= MAX_HARVEST_BATCH, "CATA: batch");
        for (uint256 i = 0; i < tokenIds.length; i++) _harvest(collection, _msgSender(), tokenIds[i]);
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

    // ---------- Governance: propose / vote / execute ----------
    function propose(
        ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collectionContext
    ) external whenNotPaused returns (bytes32) {
        bool eligible = _isEligibleProposer(_msgSender(), collectionContext);
        require(eligible, "CATA: proposer not eligible");

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
        p.votesScaled = 0;
        p.executed = false;

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
            else if (t == 9) { uint256 old = bonusPoolPercentPerCycleBP; bonusPoolPercentPerCycleBP = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else { revert("CATA: unknown target"); }
            emit ProposalExecuted(id, p.newValue);
        } else if (p.pType == ProposalType.TIER_UPGRADE) {
            address c = p.collectionAddress;
            require(_eligibleForTierUpgrade(c), "CATA: prereq fail");
            CollectionMeta storage m = collectionMeta[c];
            require(m.tier == CollectionTier.UNVERIFIED, "CATA: already verified");
            m.tier = CollectionTier.VERIFIED;
            uint256 refund = m.surchargeEscrow;
            m.surchargeEscrow = 0;
            if (refund > 0) _transfer(address(this), m.registrant, refund);
            emit TierUpgraded(c, m.registrant, refund);
            emit ProposalExecuted(id, 1);
        } else {
            revert("CATA: unknown proposal");
        }

        p.executed = true;
    }

    // ---------- Voting helpers ----------
    function _isEligibleProposer(address user, address collectionContext) internal view returns (bool) {
        // Eligible if user staked in any top collection with min stake-age OR
        // if collectionContext has enough burn and user has stake-age there
        for (uint256 i = 0; i < topCollections.length; i++) {
            address coll = topCollections[i];
            uint256[] storage port = stakePortfolioByUser[coll][user];
            if (port.length == 0) continue;
            for (uint256 j = 0; j < port.length; j++) {
                StakeInfo storage si = stakeLog[coll][user][port[j]];
                if (si.currentlyStaked && block.number >= si.stakeBlock + minStakeAgeForVoting) return true;
            }
        }
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
        // full weight if voter has an aged stake in any top collection
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
        // small weight if context has enough burn and voter has aged stake there
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

    // ---------- Top Collections maintenance ----------
    function _updateTopCollectionsOnBurn(address collection) internal {
        if (!_isRegistered(collection)) return;
        uint256 burned = burnedCatalystByCollection[collection];

        // remove existing if present
        for (uint256 i = 0; i < topCollections.length; i++) {
            if (topCollections[i] == collection) {
                for (uint256 j = i; j + 1 < topCollections.length; j++) topCollections[j] = topCollections[j + 1];
                topCollections.pop();
                break;
            }
        }

        bool inserted = false;
        for (uint256 i = 0; i < topCollections.length; i++) {
            if (burned > burnedCatalystByCollection[topCollections[i]]) {
                topCollections.push(topCollections[topCollections.length - 1]);
                for (uint256 j = topCollections.length - 1; j > i; j--) topCollections[j] = topCollections[j - 1];
                topCollections[i] = collection;
                inserted = true;
                break;
            }
        }
        if (!inserted) topCollections.push(collection);

        uint256 ec = eligibleCount();
        while (topCollections.length > ec) topCollections.pop();
    }

    function _rebuildTopCollections() internal {
        uint256 total = registeredCollections.length;
        delete topCollections;
        if (total == 0) return;
        uint256 ec = eligibleCount();
        if (ec > total) ec = total;
        bool[] memory picked = new bool[](total);
        for (uint256 s = 0; s < ec; s++) {
            uint256 maxB = 0;
            uint256 maxIdx = 0;
            bool found = false;
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

    // ---------- Burner bonus bookkeeping ----------
    function _recordUserBurn(address user, uint256 amount) internal {
        if (amount == 0) return;
        burnedCatalystByAddress[user] += amount;
        lastBurnBlock[user] = block.number;
        if (!isParticipating[user]) {
            isParticipating[user] = true;
            participatingWallets.push(user);
        }
    }

    // Admin-invoked: rebuild topBurners list (rare). O(total * topN) - acceptable as admin-only.
    function rebuildTopBurners(uint256 topN) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(topN > 0, "CATA: topN>0");

        uint256 total = participatingWallets.length;
        if (total == 0) { delete topBurners; emit TopBurnersRebuilt(_msgSender(), 0); return; }

        address[] memory selected = new address[](topN);
        bool[] memory picked = new bool[](total);

        for (uint256 s = 0; s < topN; s++) {
            uint256 maxBurn = 0;
            uint256 maxIdx = 0;
            bool found = false;
            for (uint256 i = 0; i < total; i++) {
                if (picked[i]) continue;
                address cand = participatingWallets[i];
                // eligibility: burned >= minBurnForRanking OR currently staked >= minStakedNFTsForBonus
                uint256 totalUserStaked = _totalStakedByUser(cand);
                bool eligibleByStake = totalUserStaked >= minStakedNFTsForBonus;
                bool eligibleByBurn = burnedCatalystByAddress[cand] >= minBurnForRanking;
                if (!eligibleByBurn && !eligibleByStake) continue;
                uint256 b = burnedCatalystByAddress[cand];
                if (!found || b > maxBurn) { maxBurn = b; maxIdx = i; found = true; }
            }
            if (found) { picked[maxIdx] = true; selected[s] = participatingWallets[maxIdx]; } else { break; }
        }

        delete topBurners;
        for (uint256 k = 0; k < topN; k++) {
            if (selected[k] == address(0)) break;
            topBurners.push(selected[k]);
        }

        emit TopBurnersRebuilt(_msgSender(), topBurners.length);
    }

    function _totalStakedByUser(address user) internal view returns (uint256 total) {
        total = 0;
        uint256 rc = registeredCollections.length;
        for (uint256 i = 0; i < rc; i++) {
            address coll = registeredCollections[i];
            total += stakePortfolioByUser[coll][user].length;
        }
    }

    // ---------- Distribute Top-1% Burner Bonus ----------
    function distributeTopBurnersBonus() external nonReentrant whenNotPaused onlyRole(CONTRACT_ADMIN_ROLE) {
        require(block.number >= lastBonusCycleBlock + bonusCycleLengthBlocks, "CATA: cycle not ready");

        uint256 participants = participatingWallets.length;
        require(participants > 0, "CATA: no participants");

        uint256 topCount = (participants * 1) / 100;
        if (topCount == 0) topCount = 1;

        require(topBurners.length >= topCount, "CATA: topBurners too small");

        // Use internal treasuryBalance as source
        uint256 treasuryBal = treasuryBalance;
        require(treasuryBal > 0, "CATA: empty treasury");
        uint256 pool = (treasuryBal * bonusPoolPercentPerCycleBP) / 10000;
        require(pool > 0, "CATA: pool zero");

        uint256 totalBurnTop = 0;
        address[] memory recipients = new address[](topCount);
        uint256 filled = 0;
        for (uint256 i = 0; i < topCount; i++) {
            address a = topBurners[i];
            if (a == address(0)) continue;
            uint256 totalUserStaked = _totalStakedByUser(a);
            if (burnedCatalystByAddress[a] < minBurnToEnterTopPercent && totalUserStaked < minStakedNFTsForBonus) continue;
            recipients[filled] = a;
            totalBurnTop += burnedCatalystByAddress[a];
            filled++;
        }

        require(filled > 0, "CATA: no eligible top burners");
        // decrement treasuryBalance for the pool upfront
        treasuryBalance -= pool;

        for (uint256 j = 0; j < filled; j++) {
            address r = recipients[j];
            uint256 share = (pool * burnedCatalystByAddress[r]) / totalBurnTop;
            if (share > 0) _transfer(address(this), r, share);
        }

        lastBonusCycleBlock = block.number;
        emit BurnerBonusDistributed(block.number, pool, filled);
    }

    // ---------- Admin setters & rescue ----------
    function setTopPercent(uint256 p) external onlyRole(CONTRACT_ADMIN_ROLE) { require(p>=1 && p<=100,"CATA:1..100"); topPercent=p; _rebuildTopCollections(); }
    function setCollectionVoteCapPercent(uint256 p) external onlyRole(CONTRACT_ADMIN_ROLE) { require(p>=1 && p<=100,"CATA:1..100"); collectionVoteCapPercent=p; }
    function setMinStakeAgeForVoting(uint256 blocks_) external onlyRole(CONTRACT_ADMIN_ROLE) { minStakeAgeForVoting=blocks_; }
    function setMaxBaseRewardRate(uint256 cap_) external onlyRole(CONTRACT_ADMIN_ROLE) { maxBaseRewardRate=cap_; }

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

    function setTierProposalCooldown(uint256 blocks_) external onlyRole(CONTRACT_ADMIN_ROLE) { tierProposalCooldownBlocks = blocks_; }
    function setSurchargeForfeitBlocks(uint256 blocks_) external onlyRole(CONTRACT_ADMIN_ROLE) { surchargeForfeitBlocks = blocks_; }

    function setBonusCycleLengthBlocks(uint256 blocks_) external onlyRole(CONTRACT_ADMIN_ROLE) { bonusCycleLengthBlocks = blocks_; }
    function setBonusPoolPercentPerCycleBP(uint256 bp_) external onlyRole(CONTRACT_ADMIN_ROLE) { require(bp_ <= 10000, "CATA: bp<=10000"); bonusPoolPercentPerCycleBP = bp_; }
    function setMinBurnForRanking(uint256 amt) external onlyRole(CONTRACT_ADMIN_ROLE) { minBurnForRanking = amt; }
    function setMinStakedNFTsForBonus(uint256 n) external onlyRole(CONTRACT_ADMIN_ROLE) { minStakedNFTsForBonus = n; }
    function setMinBurnToEnterTopPercent(uint256 amt) external onlyRole(CONTRACT_ADMIN_ROLE) { minBurnToEnterTopPercent = amt; }

    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); emit Paused(_msgSender()); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); emit Unpaused(_msgSender()); }

    function addContractAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) { grantRole(CONTRACT_ADMIN_ROLE, admin); emit AdminAdded(admin); }
    function removeContractAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) { revokeRole(CONTRACT_ADMIN_ROLE, admin); emit AdminRemoved(admin); }

    function emergencyWithdrawERC20(address token, address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(to != address(0), "CATA: bad to"); IERC20(token).transfer(to, amount);
    }
    function rescueERC721(address token, uint256 tokenId, address to) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(to != address(0), "CATA: bad to"); IERC721(token).safeTransferFrom(address(this), to, tokenId);
    }

    // ---------- Withdraw treasury (admin) ----------
    function withdrawTreasury(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(to != address(0), "CATA: invalid to");
        require(amount > 0, "CATA: zero amount");
        require(amount <= treasuryBalance, "CATA: insufficient treasury");

        treasuryBalance -= amount;
        _transfer(address(this), to, amount);
        emit TreasuryWithdrawal(to, amount);
    }

    // ---------- Helpers & math ----------
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
        if (rate > 90) return 90; // hard cap to avoid 100%+ burn
        return rate;
    }

    // ---------- Views ----------
    function getTopCollections() external view returns (address[] memory) { return topCollections; }
    function getRegisteredCollections() external view returns (address[] memory) { return registeredCollections; }
    function getTopBurners() external view returns (address[] memory) { return topBurners; }
    function getParticipatingWallets() external view returns (address[] memory) { return participatingWallets; }
    function getProposal(bytes32 id) external view returns (Proposal memory) { return proposals[id]; }
    function getCollectionMeta(address c) external view returns (CollectionMeta memory) { return collectionMeta[c]; }

    // ERC721 Receiver
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ---------- End of contract ----------
}
