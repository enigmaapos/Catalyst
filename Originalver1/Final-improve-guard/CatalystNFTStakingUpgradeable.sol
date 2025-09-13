// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StakingLib.sol";
import "./GovernanceLib.sol";
import "./BluechipLib.sol";
import "./GuardianLib.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract CatalystNFTStakingUpgradeable is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IERC721Receiver
{
    using StakingLib for StakingLib.Storage;
    using GovernanceLib for GovernanceLib.Storage;
    using BluechipLib for BluechipLib.Storage;
    using GuardianLib for GuardianLib.Storage;

    // -------- Errors --------
    error ZeroAddress();
    error BadParam();
    error NotRegistered();
    error AlreadyExists();
    error NotStaked();
    error TermNotExpired();
    error Cooldown();
    error BatchTooLarge();
    error Ineligible();
    error Unauthorized();
    error NoRequest();
    error Expired();
    error AlreadyApproved();
    error Threshold();
    error Insufficient();
    error AlreadyEnrolled();
    error DuplicateGuardian();

    // -------- Roles --------
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // -------- Constants & caps --------
    uint256 public constant BURN_BP = 9000;
    uint256 public constant TREASURY_BP = 900;
    uint256 public constant DEPLOYER_BP = 100;
    uint256 public constant BP_DENOM = 10000;

    uint256 public constant GLOBAL_CAP = StakingLib.GLOBAL_CAP;
    uint256 public constant TERM_CAP = StakingLib.TERM_CAP;
    uint256 public constant PERM_CAP = StakingLib.PERM_CAP;

    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public constant MAX_STAKE_PER_COLLECTION = 20_000;
    uint256 public constant WEIGHT_SCALE = 1e18;

    uint256 public constant RECOVERY_WINDOW = 3 days;

    // -------- Library storage --------
    StakingLib.Storage internal s;
    GovernanceLib.Storage internal g;
    BluechipLib.Storage internal b;
    GuardianLib.Storage internal gu; // New storage for GuardianLib

    // -------- Protocol params --------
    uint256 public numberOfBlocksPerRewardUnit;
    uint256 public termDurationBlocks;
    uint256 public stakingCooldownBlocks;
    uint256 public rewardRateIncrementPerNFT;
    uint256 public initialHarvestBurnFeeRate;
    uint256 public unstakeBurnFee;
    uint256 public collectionRegistrationFee;
    address public treasuryAddress;
    address public deployerAddress;
    uint256 public treasuryBalance;
    uint256 public minStakeAgeForVoting;
    uint256 public maxBaseRewardRate;
    address[] public registeredCollections;
    mapping(address => uint256) public registeredIndex;
    mapping(address => uint256) public burnedCatalystByAddress;
    mapping(address => uint256) public lastStakingBlock;

    // -------- Events (kept) --------
	event BluechipCollectionSet(address indexed collection, bool isBluechip);
    event CollectionAdded(address indexed collection, uint256 declaredSupply, uint256 paid);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId, bool permanent);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 gross, uint256 burned);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);

    event BaseRewardRateUpdated(uint256 oldValue, uint256 newValue);
    event HarvestFeeUpdated(uint256 oldValue, uint256 newValue);
    event UnstakeFeeUpdated(uint256 oldValue, uint256 newValue);
    event RegistrationFeeUpdated(uint256 oldValue, uint256 newValue);
    event VotingParamUpdated(uint8 target, uint256 oldValue, uint256 newValue);
    event ProposalExecuted(bytes32 indexed id, uint256 appliedValue);

    // -------- Initializer --------
    struct InitConfig {
        address owner;
        uint256 rewardRateIncrementPerNFT;
        uint256 initialHarvestBurnFeeRate;
        uint256 unstakeBurnFee;
        uint256 termDurationBlocks;
        uint256 numberOfBlocksPerRewardUnit;
        uint256 collectionRegistrationFee;
        uint256 stakingCooldownBlocks;
        uint256 votingDurationBlocks;
        uint256 minVotesRequiredScaled;
        uint256 collectionVoteCapPercent;
        uint256 minStakeAgeForVoting;
        uint256 maxBaseRewardRate;
        address[] deployerGuardians;
        uint256 deployerThreshold;
        address[] adminGuardians;
        uint256 adminThreshold;
        uint256 bluechipWalletFee;
    }

    function initialize(InitConfig calldata cfg) external initializer {
        if (cfg.owner == address(0)) revert ZeroAddress();

        __ERC20_init("Catalyst", "CATA");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, cfg.owner);
        _grantRole(CONTRACT_ADMIN_ROLE, cfg.owner);

        deployerAddress = cfg.owner;
        treasuryAddress = address(this);
        rewardRateIncrementPerNFT = cfg.rewardRateIncrementPerNFT;
        initialHarvestBurnFeeRate = cfg.initialHarvestBurnFeeRate;
        unstakeBurnFee = cfg.unstakeBurnFee;
        termDurationBlocks = cfg.termDurationBlocks;
        numberOfBlocksPerRewardUnit = cfg.numberOfBlocksPerRewardUnit;
        collectionRegistrationFee = cfg.collectionRegistrationFee;
        stakingCooldownBlocks = cfg.stakingCooldownBlocks;
        minStakeAgeForVoting = cfg.minStakeAgeForVoting;
        maxBaseRewardRate = cfg.maxBaseRewardRate == 0 ? type(uint256).max : cfg.maxBaseRewardRate;

        GovernanceLib.initGov(
            g,
            cfg.votingDurationBlocks,
            cfg.minVotesRequiredScaled,
            cfg.collectionVoteCapPercent
        );
        
        gu.init(
            cfg.deployerGuardians,
            cfg.deployerThreshold,
            cfg.adminGuardians,
            cfg.adminThreshold
        );

        b.bluechipWalletFee = cfg.bluechipWalletFee;
        _mint(cfg.owner, 100_000_000 * 1e18);
    }
    
    // -------- Modifiers --------
    modifier onlyDeployerGuardian() {
        if (!gu.isGuardian(gu, GuardianLib.DEPLOYER_COUNCIL_ID, _msgSender())) revert Unauthorized();
        _;
    }
    modifier onlyAdminGuardian() {
        if (!gu.isGuardian(gu, GuardianLib.ADMIN_COUNCIL_ID, _msgSender())) revert Unauthorized();
        _;
    }

    // [All other modifiers remain unchanged]

    // -------- Guardians: admin setters --------
    function setDeployerGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gu.setGuardian(gu, GuardianLib.DEPLOYER_COUNCIL_ID, idx, guardian);
    }
    function setAdminGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gu.setGuardian(gu, GuardianLib.ADMIN_COUNCIL_ID, idx, guardian);
    }
    
    // -------- Deployer recovery --------
    function proposeDeployerRecovery(address newDeployer) external whenNotPaused onlyDeployerGuardian {
        gu.proposeRecovery(gu, GuardianLib.DEPLOYER_COUNCIL_ID, newDeployer, RECOVERY_WINDOW, _msgSender());
    }
    function approveDeployerRecovery() external whenNotPaused onlyDeployerGuardian {
        if (gu.approveRecovery(gu, GuardianLib.DEPLOYER_COUNCIL_ID, _msgSender()) < gu.deployerCouncil.threshold) {
            revert Threshold();
        }
    }
    function executeDeployerRecovery() external whenNotPaused {
        address old = deployerAddress;
        address newDeployer = gu.executeRecovery(gu, GuardianLib.DEPLOYER_COUNCIL_ID);
        deployerAddress = newDeployer;
        emit DeployerRecovered(old, newDeployer);
    }

    // -------- Admin recovery --------
    function proposeAdminRecovery(address newAdmin) external whenNotPaused onlyAdminGuardian {
        gu.proposeRecovery(gu, GuardianLib.ADMIN_COUNCIL_ID, newAdmin, RECOVERY_WINDOW, _msgSender());
    }
    function approveAdminRecovery() external whenNotPaused onlyAdminGuardian {
        if (gu.approveRecovery(gu, GuardianLib.ADMIN_COUNCIL_ID, _msgSender()) < gu.adminCouncil.threshold) {
            revert Threshold();
        }
    }
    function executeAdminRecovery() external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        address newAdmin = gu.executeRecovery(gu, GuardianLib.ADMIN_COUNCIL_ID);
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        emit AdminRecovered(newAdmin);
    }
    
    // [All other functions remain unchanged]
    
}
