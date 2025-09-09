// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* ========= Local Libraries ========= */
// We no longer import the local library files directly, we will use interfaces instead
// import "./StakingLib.sol";
// import "./GovernanceLib.sol";
// import "./BluechipLib.sol";
// import "./GuardianLib.sol";

/* ========= OpenZeppelin (Upgradeable) ========= */
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/* ========= Library Interfaces (new) ========= */
interface IStakingLib {
    struct Storage {
        uint256 totalStakedAll;
        uint256 totalStakedTerm;
        uint256 totalStakedPermanent;
        mapping(address => mapping(address => mapping(uint256 => StakeInfo))) stakeLog;
        mapping(address => mapping(address => uint256[])) stakePortfolioByUser;
        mapping(address => mapping(uint256 => uint256)) indexOfTokenIdInStakePortfolio;
        uint256 totalStakedNFTsCount;
        uint256 baseRewardRate;
        mapping(address => CollectionConfig) collectionConfigs;
    }
    struct StakeInfo {
        uint256 stakeBlock;
        uint256 lastHarvestBlock;
        bool currentlyStaked;
        bool isPermanent;
        uint256 unstakeDeadlineBlock;
    }
    struct CollectionConfig {
        uint256 totalStaked;
        uint256 totalStakers;
        bool registered;
        uint256 declaredSupply;
    }
    function init(Storage storage s) external;
    function initCollection(Storage storage s, address collection, uint256 declaredSupply) external;
    function recordTermStake(Storage storage s, address collection, address staker, uint256 tokenId, uint256 currentBlock, uint256 termDurationBlocks, uint256 rewardRateIncrementPerNFT) external;
    function recordPermanentStake(Storage storage s, address collection, address staker, uint256 tokenId, uint256 currentBlock, uint256 rewardRateIncrementPerNFT) external;
    function recordUnstake(Storage storage s, address collection, address staker, uint256 tokenId, bool wasPermanent) external;
    function pendingRewards(Storage storage s, address collection, address owner, uint256 tokenId, uint256 numberOfBlocksPerRewardUnit) external view returns (uint256);
    function updateLastHarvest(Storage storage s, address collection, address owner, uint256 tokenId) external;
}

interface IGovernanceLib {
    struct Storage {
        mapping(bytes32 => Proposal) proposals;
        mapping(bytes32 => mapping(address => bool)) hasVoted;
        mapping(bytes32 => mapping(address => uint256)) proposalCollectionVotesScaled;
        uint256 votingDurationBlocks;
        uint256 minVotesRequiredScaled;
        uint256 collectionVoteCapPercent;
    }
    enum ProposalType {
        BASE_REWARD, HARVEST_FEE, UNSTAKE_FEE, REGISTRATION_FEE_FALLBACK, VOTING_PARAM, TIER_UPGRADE
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
    function init(Storage storage g, uint256 votingDurationBlocks_, uint256 minVotesRequiredScaled_, uint256 collectionVoteCapPercent_) external;
    function createProposal(Storage storage g, bytes32 id, ProposalType pType, uint8 paramTarget, address collection, address proposer, uint256 newValue, uint256 startBlock, uint256 endBlock) external;
    function vote(Storage storage g, bytes32 id, address voter, uint256 weightScaled, address attributedCollection) external;
    function validateForExecution(Storage storage g, bytes32 id) external view returns (Proposal memory);
    function markExecuted(Storage storage g, bytes32 id) external;
}

interface IBluechipLib {
    struct Storage {
        mapping(address => mapping(address => WalletEnrollment)) bluechipWallets;
        mapping(address => bool) isBluechipCollection;
        uint256 bluechipWalletFee;
    }
    struct WalletEnrollment {
        bool enrolled;
        uint256 lastHarvestBlock;
    }
    function init(Storage storage b, uint256 fee) external;
    function register(Storage storage b, address collection) external;
    function enroll(Storage storage b, address collection, address wallet, uint256 blockNum, uint256 fee, function(address,uint256) external feeHandler) external;
    function harvest(Storage storage b, address collection, address wallet, uint256 blockNum, uint256 baseRewardRate, uint256 blocksPerRewardUnit, function(address,uint256) external mintReward) external;
}

interface IGuardianLib {
    struct RecoveryRequest {
        address proposed;
        uint64 deadline;
        uint8 approvals;
        bool executed;
    }
    struct Storage {
        address[] deployerGuardians;
        address[] adminGuardians;
        mapping(address => bool) isDeployerGuardian;
        mapping(address => bool) isAdminGuardian;
        mapping(address => bool) deployerHasApproved;
        mapping(address => bool) adminHasApproved;
        address deployerRecoveryProposer;
        address adminRecoveryProposer;
        RecoveryRequest deployerRecovery;
        RecoveryRequest adminRecovery;
        address deployerGuardianCouncil;
    }
    function init(Storage storage gu, address deployer) external;
    function setDeployerGuardian(Storage storage gu, uint8 idx, address guardian) external;
    function setAdminGuardian(Storage storage gu, uint8 idx, address guardian) external;
    function proposeDeployerRecovery(Storage storage gu, address proposedDeployer) external;
    function approveDeployerRecovery(Storage storage gu, address approver) external;
    function executeDeployerRecovery(Storage storage gu) external returns (address newDeployer);
    function proposeAdminRecovery(Storage storage gu, address newAdmin) external;
    function approveAdminRecovery(Storage storage gu, address approver) external;
    function executeAdminRecovery(Storage storage gu) external returns (address newAdmin);
    function getStorage(Storage storage gu) external view returns (Storage memory);
}


contract CatalystNFTStakingUpgradeable is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IERC721Receiver
{
    // The `using ... for ...` statements are removed to prevent code inlining.
    // using StakingLib  for StakingLib.Storage;
    // using GovernanceLib for GovernanceLib.Storage;
    // using BluechipLib for BluechipLib.Storage;
    // using GuardianLib for GuardianLib.Storage;

    /* ========= Custom Errors ========= */
    error ZeroAddress();
    error BadParam();
    error NotRegistered();
    error AlreadyExists();
    error NotERC721Sender();
    error StakeInfoNotSet();
    error AlreadyStaked();
    error NotStaked();
    error UnstakeExpired();
    error NotPermanent();
    error NotDeployer();
    error Unauthorized();
    error MissingParams();
    error NotEnoughTokens();

    /* ========= Protocol Parameters ========= */
    uint256 public constant SECONDS_PER_BLOCK = 12;
    uint256 public constant BLOCKS_PER_DAY    = (60 * 60 * 24) / SECONDS_PER_BLOCK;
    uint256 public constant GLOBAL_CAP        = 1_000_000_000;
    uint256 public constant TERM_CAP          = 750_000_000;
    uint256 public constant PERM_CAP          = 250_000_000;
    uint256 public numberOfBlocksPerRewardUnit;

    /* ========= Roles ========= */
    bytes32 public constant CONTRACT_DEPLOYER_ROLE = keccak256("CONTRACT_DEPLOYER_ROLE");
    bytes32 public constant CONTRACT_ADMIN_ROLE    = keccak256("CONTRACT_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE            = keccak256("PAUSER_ROLE");

    /* ========= Events ========= */
    event Staked(address indexed owner, address indexed collection, uint256 indexed tokenId, bool isPermanent);
    event Unstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event Harvested(address indexed owner, uint256 amount);
    event CollectionRegistered(address indexed collection);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event StakingParamsUpdated(uint256 newTermDurationBlocks, uint256 newBaseRewardRateIncrementPerNFT);

    /* ========= Library Storage ========= */
    IStakingLib.Storage internal s;
    IGovernanceLib.Storage internal g;
    IBluechipLib.Storage internal b;
    IGuardianLib.Storage internal gu;

    /* ========= Library Addresses (new) ========= */
    IStakingLib private sLib;
    IGovernanceLib private gLib;
    IBluechipLib private bLib;
    IGuardianLib private guLib;
    
    // ... (rest of the state variables)
    uint256 public stakingTermDurationBlocks;
    uint256 public baseRewardRateIncrementPerNFT;
    mapping(address => uint256) public registeredIndex;
    address[] public registeredCollections;
    uint256 public treasury;
    uint256 public unstakeFee;
    uint256 public registrationFee;

    /* ========= Initializer (modified) ========= */
    struct InitConfig {
        address stakingLib;
        address governanceLib;
        address bluechipLib;
        address guardianLib;
        uint256 initialSupply;
        uint256 _stakingTermDurationDays;
        uint256 _baseRewardRateIncrementPerNFT;
        uint256 _minVotesRequiredScaled;
        uint256 _collectionVoteCapPercent;
    }

    function initialize(InitConfig calldata cfg) external initializer {
        __ERC20_init("Catalyst", "CATA");
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONTRACT_DEPLOYER_ROLE, msg.sender);
        _grantRole(CONTRACT_ADMIN_ROLE, msg.sender);

        // Set library addresses
        sLib = IStakingLib(cfg.stakingLib);
        gLib = IGovernanceLib(cfg.governanceLib);
        bLib = IBluechipLib(cfg.bluechipLib);
        guLib = IGuardianLib(cfg.guardianLib);

        // Call initializer functions on the libraries
        sLib.init(s);
        gLib.init(g, cfg.votingDurationBlocks, cfg.minVotesRequiredScaled, cfg.collectionVoteCapPercent);
        bLib.init(b, 0); // Assuming no initial bluechip fee
        guLib.init(gu, msg.sender);

        stakingTermDurationBlocks = cfg._stakingTermDurationDays * BLOCKS_PER_DAY;
        baseRewardRateIncrementPerNFT = cfg._baseRewardRateIncrementPerNFT;
        _mint(msg.sender, cfg.initialSupply);
        unstakeFee = 0;
        registrationFee = 0;
        treasury = 0;
    }

    /* ========= Staking + Unstaking + Harvesting ========= */

    function stake(address collection, uint256 tokenId, bool isPermanent) external nonReentrant whenNotPaused {
        if (registeredIndex[collection] == 0) revert NotRegistered();
        if (isPermanent) {
            sLib.recordPermanentStake(s, collection, msg.sender, tokenId, block.number, baseRewardRateIncrementPerNFT);
        } else {
            sLib.recordTermStake(s, collection, msg.sender, tokenId, block.number, stakingTermDurationBlocks, baseRewardRateIncrementPerNFT);
        }
        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);
        emit Staked(msg.sender, collection, tokenId, isPermanent);
    }

    function unstake(address collection, uint256 tokenId) external nonReentrant {
        IStakingLib.StakeInfo memory info = s.stakeLog[collection][msg.sender][tokenId];
        if (!info.currentlyStaked) revert NotStaked();
        if (!info.isPermanent && block.number < info.unstakeDeadlineBlock) revert UnstakeExpired();
        
        if (info.isPermanent) {
            _burn(msg.sender, unstakeFee);
            treasury += unstakeFee;
        }

        sLib.recordUnstake(s, collection, msg.sender, tokenId, info.isPermanent);
        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);
        emit Unstaked(msg.sender, collection, tokenId);
    }

    function harvest(address collection, uint256 tokenId) external nonReentrant {
        uint256 rewards = sLib.pendingRewards(s, collection, msg.sender, tokenId, numberOfBlocksPerRewardUnit);
        if (rewards == 0) revert StakeInfoNotSet();
        _mint(msg.sender, rewards);
        sLib.updateLastHarvest(s, collection, msg.sender, tokenId);
        emit Harvested(msg.sender, rewards);
    }

    /* ========= Collection Management ========= */

    function registerCollection(address collection, uint256 declaredSupply) external onlyRole(CONTRACT_ADMIN_ROLE) {
        if (registeredIndex[collection] != 0) revert AlreadyExists();
        if (declaredSupply == 0) revert BadParam();
        _burn(msg.sender, registrationFee);
        treasury += registrationFee;
        
        registeredCollections.push(collection);
        registeredIndex[collection] = registeredCollections.length;
        sLib.initCollection(s, collection, declaredSupply);
        emit CollectionRegistered(collection);
    }

    function removeCollection(address collection) external onlyRole(CONTRACT_ADMIN_ROLE) {
        if (registeredIndex[collection] == 0) revert NotRegistered();
        
        uint256 lastIndex = registeredCollections.length - 1;
        uint256 collectionIndex = registeredIndex[collection] - 1;
        address lastCollection = registeredCollections[lastIndex];

        registeredCollections[collectionIndex] = lastCollection;
        registeredIndex[lastCollection] = collectionIndex + 1;
        registeredCollections.pop();
        delete registeredIndex[collection];
    }
    
    /* ========= Governance ========= */
    function propose(uint256 _newValue, bytes32 proposalType) external {
        // ...
    }
    
    function vote(bytes32 _proposalId) external {
        // ...
    }

    /* ========= Admin & Guardian Functions ========= */

    function setStakingParams(uint256 _stakingTermDurationDays, uint256 _baseRewardRateIncrementPerNFT) external onlyRole(CONTRACT_ADMIN_ROLE) {
        stakingTermDurationBlocks = _stakingTermDurationDays * BLOCKS_PER_DAY;
        baseRewardRateIncrementPerNFT = _baseRewardRateIncrementPerNFT;
        emit StakingParamsUpdated(stakingTermDurationBlocks, baseRewardRateIncrementPerNFT);
    }

    function setFee(uint256 _newUnstakeFee, uint256 _newRegistrationFee) external onlyRole(CONTRACT_ADMIN_ROLE) {
        unstakeFee = _newUnstakeFee;
        registrationFee = _newRegistrationFee;
    }

    function withdrawTreasury(address to, uint256 amount) external onlyRole(CONTRACT_DEPLOYER_ROLE) {
        if (treasury < amount) revert NotEnoughTokens();
        _mint(to, amount);
        treasury -= amount;
    }

    function setDeployerGuardian(uint8 idx, address guardian) external {
        guLib.setDeployerGuardian(gu, idx, guardian);
    }

    function setAdminGuardian(uint8 idx, address guardian) external {
        guLib.setAdminGuardian(gu, idx, guardian);
    }

    function proposeDeployerRecovery(address proposedDeployer) external {
        guLib.proposeDeployerRecovery(gu, proposedDeployer);
    }

    function approveDeployerRecovery() external {
        guLib.approveDeployerRecovery(gu, msg.sender);
    }

    function executeDeployerRecovery() external {
        address newDeployer = guLib.executeDeployerRecovery(gu);
        grantRole(CONTRACT_DEPLOYER_ROLE, newDeployer);
    }

    function proposeAdminRecovery(address newAdmin) external {
        guLib.proposeAdminRecovery(gu, newAdmin);
    }
    
    function approveAdminRecovery() external {
        guLib.approveAdminRecovery(gu, msg.sender);
    }

    function executeAdminRecovery() external {
        address newAdmin = guLib.executeAdminRecovery(gu);
        grantRole(CONTRACT_ADMIN_ROLE, newAdmin);
    }
    
    /* ========= View Functions ========= */

    function getStakingStatus()
        external
        view
        returns (
            uint256 totalAll,
            uint256 totalTerm,
            uint256 totalPermanent,
            uint256 remainingGlobal,
            uint256 remainingTerm,
            uint256 remainingPermanent
        )
    {
        totalAll = s.totalStakedAll;
        totalTerm = s.totalStakedTerm;
        totalPermanent = s.totalStakedPermanent;
        remainingGlobal = GLOBAL_CAP > totalAll ? GLOBAL_CAP - totalAll : 0;
        remainingTerm = TERM_CAP > totalTerm ? TERM_CAP - totalTerm : 0;
        remainingPermanent = PERM_CAP > totalPermanent ? PERM_CAP - totalPermanent : 0;
    }

    function pendingRewardsView(address collection, address owner, uint256 tokenId)
        external
        view
        returns (uint256)
    {
        return sLib.pendingRewards(s, collection, owner, tokenId, numberOfBlocksPerRewardUnit);
    }

    function collectionCount() external view returns (uint256) {
        return registeredCollections.length;
    }

    /* ========= ERC721 Receiver + Pause + UUPS ========= */
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (registeredIndex[msg.sender] == 0) revert NotERC721Sender();
        return this.onERC721Received.selector;
    }

    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }

    function _authorizeUpgrade(address) internal override onlyRole(CONTRACT_DEPLOYER_ROLE) {}
}
