// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StakingLib.sol";
import "./GovernanceLib.sol";

// OpenZeppelin upgradeable imports
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title CatalystNFTStaking (Upgradeable) with Guardian Council Security Systems
/// @dev Combined GCSS (deployer) + AGC (admin), safe revoke, staking, governance wrappers.
contract CatalystNFTStaking is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IERC721Receiver
{
    using StakingLib for StakingLib.Storage;

    // ------------------------
    // Custom errors (compact)
    // ------------------------
    error ZeroAddress();
    error AlreadyExists();
    error NotGuardian();
    error AlreadyApproved();
    error RequestExpired();
    error ThresholdNotMet();
    error NoActiveRequest();
    error AlreadyExecuted();
    error NotEligible();
    error CooldownActive();
    error InsufficientBalance();
    error NotRegistered();
    error CapReached();
    error AlreadyStaked();
    error NotStaked();
    error TermActive();
    error FeeTooHigh();
    error BadParam();
    error Unauthorized();

    // ------------------------
    // Roles
    // ------------------------
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // ------------------------
    // Constants
    // ------------------------
    uint256 public constant BURN_BP = 9000;
    uint256 public constant TREASURY_BP = 900;
    uint256 public constant DEPLOYER_BP = 100;

    uint256 public constant WEIGHT_SCALE = 1e18;
    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public constant MAX_STAKE_PER_COLLECTION = 20000;

    // Staking caps mirrored from StakingLib
    uint256 public constant GLOBAL_CAP = 1_000_000_000;
    uint256 public constant TERM_CAP   = 750_000_000;
    uint256 public constant PERM_CAP   = 250_000_000;

    // ------------------------
    // Library storage
    // ------------------------
    StakingLib.Storage internal s;
    GovernanceLib.Storage internal g;

    // ------------------------
    // Protocol parameters
    // ------------------------
    uint256 public numberOfBlocksPerRewardUnit;
    uint256 public collectionRegistrationFee;
    uint256 public unstakeBurnFee;
    address public treasuryAddress;
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

    // registration fee brackets
    uint256 public SMALL_MIN_FEE;
    uint256 public SMALL_MAX_FEE;
    uint256 public MED_MIN_FEE;
    uint256 public MED_MAX_FEE;
    uint256 public LARGE_MIN_FEE;
    uint256 public LARGE_MAX_FEE_CAP;
    uint256 public unverifiedSurchargeBP;

    uint256 public minStakeAgeForVoting;
    uint256 public maxBaseRewardRate;

    // registration enumeration
    address[] public registeredCollections;
    mapping(address => uint256) public registeredIndex;

    // burner bookkeeping
    mapping(address => uint256) public burnedCatalystByAddress;
    mapping(address => uint256) public lastBurnBlock;
    mapping(address => bool) public isParticipating;
    address[] public participatingWallets;

    // treasury accounting
    uint256 public treasuryBalance;

    // staking cooldown
    mapping(address => uint256) public lastStakingBlock;

    // ------------------------
    // Guardian councils
    // ------------------------
    // Deployer GCSS
    address public deployerAddress;
    uint8 public constant DEPLOYER_GCOUNT = 7;
    uint8 public constant DEPLOYER_THRESHOLD = 5;
    address[DEPLOYER_GCOUNT] public deployerGuardians;
    mapping(address => bool) public isDeployerGuardian;

    // Admin GCSS (AGC)
    address public primaryAdmin; // tracked default admin
    uint8 public constant ADMIN_GCOUNT = 7;
    uint8 public constant ADMIN_THRESHOLD = 5;
    address[ADMIN_GCOUNT] public adminGuardians;
    mapping(address => bool) public isAdminGuardian;

    // single active recovery request per council
    struct Recovery {
        address proposed;
        uint8 approvals;
        uint256 deadline;
        bool executed;
    }
    uint256 public constant RECOVERY_WINDOW = 3 days;
    Recovery public deployerRecovery;
    mapping(address => bool) public deployerHasApproved;

    Recovery public adminRecovery;
    mapping(address => bool) public adminHasApproved;

    // ------------------------
    // Events
    // ------------------------
    event CollectionAdded(address indexed collection, uint256 declaredSupply, uint256 baseFee, uint256 surcharge, uint8 tier);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId, bool permanent);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payout, uint256 burned);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);

    event DeployerRecoveryProposed(address indexed guardian, address proposed, uint256 deadline);
    event DeployerRecoveryApproved(address indexed guardian, uint8 approvals);
    event DeployerRecovered(address indexed oldDeployer, address indexed newDeployer);

    event AdminRecoveryProposed(address indexed guardian, address proposed, uint256 deadline);
    event AdminRecoveryApproved(address indexed guardian, uint8 approvals);
    event AdminRecovered(address indexed newAdmin);

    event GuardianSet(bytes32 indexed council, uint8 index, address guardian);

    event BaseRewardRateUpdated(uint256 oldValue, uint256 newValue);
    event HarvestFeeUpdated(uint256 oldValue, uint256 newValue);
    event UnstakeFeeUpdated(uint256 oldValue, uint256 newValue);
    event RegistrationFeeUpdated(uint256 oldValue, uint256 newValue);
    event VotingParamUpdated(uint8 target, uint256 oldValue, uint256 newValue);
    event ProposalExecuted(bytes32 indexed id, uint256 appliedValue);

    // ------------------------
    // Initializer struct
    // ------------------------
    struct InitConfig {
        address owner;
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
        uint256 votingDurationBlocks;
        uint256 minVotesRequiredScaled;
        uint256 collectionVoteCapPercent;
        address[DEPLOYER_GCOUNT] deployerGuardians;
        address[ADMIN_GCOUNT] adminGuardians;
    }

    // ------------------------
    // Initializer
    // ------------------------
    function initialize(InitConfig calldata cfg) public initializer {
        if (cfg.owner == address(0)) revert ZeroAddress();

        __ERC20_init("Catalyst", "CATA");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _mint(cfg.owner, 25_185_000 * 10**18);

        _grantRole(DEFAULT_ADMIN_ROLE, cfg.owner);
        _grantRole(CONTRACT_ADMIN_ROLE, cfg.owner);
        primaryAdmin = cfg.owner;

        treasuryAddress = address(this);
        deployerAddress = cfg.owner;

        numberOfBlocksPerRewardUnit = 18782;
        collectionRegistrationFee = cfg.collectionRegistrationFeeFallback;
        unstakeBurnFee = cfg.unstakeBurnFee;
        initialHarvestBurnFeeRate = cfg.initialHarvestBurnFeeRate;
        termDurationBlocks = cfg.termDurationBlocks;
        stakingCooldownBlocks = cfg.stakingCooldownBlocks;
        harvestRateAdjustmentFactor = cfg.harvestRateAdjustmentFactor;
        minBurnContributionForVote = cfg.minBurnContributionForVote;

        initialCollectionFee = cfg.initialCollectionFee;
        feeMultiplier = cfg.feeMultiplier;
        rewardRateIncrementPerNFT = cfg.rewardRateIncrementPerNFT;
        welcomeBonusBaseRate = cfg.welcomeBonusBaseRate;
        welcomeBonusIncrementPerNFT = cfg.welcomeBonusIncrementPerNFT;

        // defaults
        SMALL_MIN_FEE = 1000 * 10**18;
        SMALL_MAX_FEE = 5000 * 10**18;
        MED_MIN_FEE   = 5000 * 10**18;
        MED_MAX_FEE   = 10000 * 10**18;
        LARGE_MIN_FEE = 10000 * 10**18;
        LARGE_MAX_FEE_CAP = 20000 * 10**18;
        unverifiedSurchargeBP = 20000;

        minStakeAgeForVoting = 100;
        maxBaseRewardRate = type(uint256).max;

        // initialize governance library
        GovernanceLib.initGov(g, cfg.votingDurationBlocks, cfg.minVotesRequiredScaled, cfg.collectionVoteCapPercent);

        // seed guardians
        for (uint8 i = 0; i < DEPLOYER_GCOUNT; i++) {
            address dg = cfg.deployerGuardians[i];
            deployerGuardians[i] = dg;
            if (dg != address(0)) isDeployerGuardian[dg] = true;
            emit GuardianSet(keccak256("DEPLOYER"), i, dg);
        }
        for (uint8 j = 0; j < ADMIN_GCOUNT; j++) {
            address ag = cfg.adminGuardians[j];
            adminGuardians[j] = ag;
            if (ag != address(0)) isAdminGuardian[ag] = true;
            emit GuardianSet(keccak256("ADMIN"), j, ag);
        }
    }

    // ------------------------
    // Guardian management (admin-only)
    // ------------------------
    function setDeployerGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (idx >= DEPLOYER_GCOUNT) revert BadParam();
        address old = deployerGuardians[idx];
        if (old != address(0)) isDeployerGuardian[old] = false;
        deployerGuardians[idx] = guardian;
        if (guardian != address(0)) isDeployerGuardian[guardian] = true;
        emit GuardianSet(keccak256("DEPLOYER"), idx, guardian);
    }

    function setAdminGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (idx >= ADMIN_GCOUNT) revert BadParam();
        address old = adminGuardians[idx];
        if (old != address(0)) isAdminGuardian[old] = false;
        adminGuardians[idx] = guardian;
        if (guardian != address(0)) isAdminGuardian[guardian] = true;
        emit GuardianSet(keccak256("ADMIN"), idx, guardian);
    }

    function removeGuardian(bytes32 council, uint8 idx) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (council == keccak256("DEPLOYER")) {
            if (idx >= DEPLOYER_GCOUNT) revert BadParam();
            address old = deployerGuardians[idx];
            if (old != address(0)) isDeployerGuardian[old] = false;
            deployerGuardians[idx] = address(0);
            emit GuardianSet(council, idx, address(0));
        } else if (council == keccak256("ADMIN")) {
            if (idx >= ADMIN_GCOUNT) revert BadParam();
            address old = adminGuardians[idx];
            if (old != address(0)) isAdminGuardian[old] = false;
            adminGuardians[idx] = address(0);
            emit GuardianSet(council, idx, address(0));
        } else revert BadParam();
    }

    function resetGuardianCouncil(bytes32 council, address[7] calldata newSet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (council == keccak256("DEPLOYER")) {
            for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
                address old = deployerGuardians[i];
                if (old != address(0)) isDeployerGuardian[old] = false;
                deployerGuardians[i] = newSet[i];
                if (newSet[i] != address(0)) isDeployerGuardian[newSet[i]] = true;
                emit GuardianSet(council, i, newSet[i]);
            }
        } else if (council == keccak256("ADMIN")) {
            for (uint8 i = 0; i < ADMIN_GCOUNT; ++i) {
                address old = adminGuardians[i];
                if (old != address(0)) isAdminGuardian[old] = false;
                adminGuardians[i] = newSet[i];
                if (newSet[i] != address(0)) isAdminGuardian[newSet[i]] = true;
                emit GuardianSet(council, i, newSet[i]);
            }
        } else revert BadParam();
    }

    // ------------------------
    // Deployer recovery flow
    // ------------------------
    modifier onlyDeployerGuardian() {
        if (!isDeployerGuardian[_msgSender()]) revert NotGuardian();
        _;
    }

    function proposeDeployerRecovery(address newDeployer) external onlyDeployerGuardian whenNotPaused {
        if (newDeployer == address(0)) revert ZeroAddress();
        deployerRecovery = Recovery({ proposed: newDeployer, approvals: 0, deadline: block.timestamp + RECOVERY_WINDOW, executed: false });
        // reset approvals map for guardians
        for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
            address gaddr = deployerGuardians[i];
            if (gaddr != address(0)) deployerHasApproved[gaddr] = false;
        }
        emit DeployerRecoveryProposed(_msgSender(), newDeployer, deployerRecovery.deadline);
    }

    function approveDeployerRecovery() external onlyDeployerGuardian whenNotPaused {
        if (deployerRecovery.proposed == address(0)) revert NoActiveRequest();
        if (deployerRecovery.executed) revert AlreadyExecuted();
        if (block.timestamp > deployerRecovery.deadline) revert RequestExpired();
        if (deployerHasApproved[_msgSender()]) revert AlreadyApproved();
        deployerHasApproved[_msgSender()] = true;
        deployerRecovery.approvals++;
        emit DeployerRecoveryApproved(_msgSender(), deployerRecovery.approvals);
    }

    function executeDeployerRecovery() external whenNotPaused {
        if (deployerRecovery.proposed == address(0)) revert NoActiveRequest();
        if (deployerRecovery.executed) revert AlreadyExecuted();
        if (block.timestamp > deployerRecovery.deadline) revert RequestExpired();
        if (deployerRecovery.approvals < DEPLOYER_THRESHOLD) revert ThresholdNotMet();

        address old = deployerAddress;
        deployerAddress = deployerRecovery.proposed;
        deployerRecovery.executed = true;

        // remove old from guardian list if present
        for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
            if (deployerGuardians[i] == old) {
                deployerGuardians[i] = address(0);
                isDeployerGuardian[old] = false;
                emit GuardianSet(keccak256("DEPLOYER"), i, address(0));
                break;
            }
        }

        emit DeployerRecovered(old, deployerAddress);
    }

    // ------------------------
    // Admin recovery flow (AGC) with safe-revoke
    // ------------------------
    modifier onlyAdminGuardian() {
        if (!isAdminGuardian[_msgSender()]) revert NotGuardian();
        _;
    }

    function proposeAdminRecovery(address newAdmin) external onlyAdminGuardian whenNotPaused {
        if (newAdmin == address(0)) revert ZeroAddress();
        adminRecovery = Recovery({ proposed: newAdmin, approvals: 0, deadline: block.timestamp + RECOVERY_WINDOW, executed: false });
        for (uint8 i = 0; i < ADMIN_GCOUNT; ++i) {
            address gaddr = adminGuardians[i];
            if (gaddr != address(0)) adminHasApproved[gaddr] = false;
        }
        emit AdminRecoveryProposed(_msgSender(), newAdmin, adminRecovery.deadline);
    }

    function approveAdminRecovery() external onlyAdminGuardian whenNotPaused {
        if (adminRecovery.proposed == address(0)) revert NoActiveRequest();
        if (adminRecovery.executed) revert AlreadyExecuted();
        if (block.timestamp > adminRecovery.deadline) revert RequestExpired();
        if (adminHasApproved[_msgSender()]) revert AlreadyApproved();
        adminHasApproved[_msgSender()] = true;
        adminRecovery.approvals++;
        emit AdminRecoveryApproved(_msgSender(), adminRecovery.approvals);
    }

    function executeAdminRecovery() external whenNotPaused {
        if (adminRecovery.proposed == address(0)) revert NoActiveRequest();
        if (adminRecovery.executed) revert AlreadyExecuted();
        if (block.timestamp > adminRecovery.deadline) revert RequestExpired();
        if (adminRecovery.approvals < ADMIN_THRESHOLD) revert ThresholdNotMet();

        address old = primaryAdmin;
        address newAdmin = adminRecovery.proposed;

        // 1) Grant DEFAULT_ADMIN_ROLE to newAdmin first
        if (!hasRole(DEFAULT_ADMIN_ROLE, newAdmin)) {
            _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        }

        // 2) Revoke old primary admin if different and holds the role
        if (old != address(0) && old != newAdmin && hasRole(DEFAULT_ADMIN_ROLE, old)) {
            _revokeRole(DEFAULT_ADMIN_ROLE, old);
        }

        // 3) mark executed and update primaryAdmin
        primaryAdmin = newAdmin;
        adminRecovery.executed = true;

        // 4) optional cleanup: remove old admin if it was a guardian
        for (uint8 i = 0; i < ADMIN_GCOUNT; ++i) {
            if (adminGuardians[i] == old) {
                adminGuardians[i] = address(0);
                isAdminGuardian[old] = false;
                emit GuardianSet(keccak256("ADMIN"), i, address(0));
                break;
            }
        }

        emit AdminRecovered(newAdmin);
    }

    // ------------------------
    // Staking functions
    // ------------------------
    modifier notInCooldown() {
        if (block.number < lastStakingBlock[_msgSender()] + stakingCooldownBlocks) revert CooldownActive();
        _;
    }

    function stake(address collection, uint256 tokenId, bool permanent) public nonReentrant notInCooldown whenNotPaused {
        if (collection == address(0)) revert ZeroAddress();
        if (!s.collectionConfigs[collection].registered) revert NotRegistered();

        // transfer NFT to contract (reverts if not approved)
        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        if (permanent) {
            uint256 fee = initialCollectionFee + (StakingLib.sqrt(s.totalStakedNFTsCount) * feeMultiplier);
            if (balanceOf(_msgSender()) < fee) revert InsufficientBalance();
            _splitFeeFromSender(_msgSender(), fee);
            StakingLib.recordPermanentStake(s, collection, _msgSender(), tokenId, block.number, rewardRateIncrementPerNFT);
            emit NFTStaked(_msgSender(), collection, tokenId, true);
        } else {
            StakingLib.recordTermStake(s, collection, _msgSender(), tokenId, block.number, termDurationBlocks, rewardRateIncrementPerNFT);
            emit NFTStaked(_msgSender(), collection, tokenId, false);
        }

        uint256 dynamicWelcome = welcomeBonusBaseRate + (s.totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
        if (dynamicWelcome > 0) _mint(_msgSender(), dynamicWelcome);

        lastStakingBlock[_msgSender()] = block.number;
    }

    function batchTermStake(address collection, uint256[] calldata tokenIds) external {
        uint256 n = tokenIds.length;
        if (n == 0 || n > MAX_HARVEST_BATCH) revert BadParam();
        for (uint256 i = 0; i < n; ++i) stake(collection, tokenIds[i], false);
    }

    function batchPermanentStake(address collection, uint256[] calldata tokenIds) external {
        uint256 n = tokenIds.length;
        if (n == 0 || n > MAX_HARVEST_BATCH) revert BadParam();
        for (uint256 i = 0; i < n; ++i) stake(collection, tokenIds[i], true);
    }

    function batchUnstake(address collection, uint256[] calldata tokenIds) external {
        uint256 n = tokenIds.length;
        if (n == 0 || n > MAX_HARVEST_BATCH) revert BadParam();
        for (uint256 i = 0; i < n; ++i) unstake(collection, tokenIds[i]);
    }

    function unstake(address collection, uint256 tokenId) public nonReentrant whenNotPaused {
        StakingLib.StakeInfo memory info = s.stakeLog[collection][_msgSender()][tokenId];
        if (!info.currentlyStaked) revert NotStaked();
        if (!info.isPermanent && block.number < info.unstakeDeadlineBlock) revert TermActive();

        uint256 reward = StakingLib.pendingRewards(s, collection, _msgSender(), tokenId, numberOfBlocksPerRewardUnit);
        if (reward > 0) {
            uint256 feeRate = initialHarvestBurnFeeRate;
            uint256 burnAmt = (reward * feeRate) / 100;
            _mint(_msgSender(), reward);
            if (burnAmt > 0) {
                _burn(_msgSender(), burnAmt);
                burnedCatalystByAddress[_msgSender()] += burnAmt;
                lastBurnBlock[_msgSender()] = block.number;
                if (!isParticipating[_msgSender()]) {
                    isParticipating[_msgSender()] = true;
                    participatingWallets.push(_msgSender());
                }
            }
            StakingLib.updateLastHarvest(s, collection, _msgSender(), tokenId);
            emit RewardsHarvested(_msgSender(), collection, reward - burnAmt, burnAmt);
        }

        if (balanceOf(_msgSender()) < unstakeBurnFee) revert InsufficientBalance();
        _splitFeeFromSender(_msgSender(), unstakeBurnFee);

        StakingLib.recordUnstake(s, collection, _msgSender(), tokenId, rewardRateIncrementPerNFT);
        IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);

        emit NFTUnstaked(_msgSender(), collection, tokenId);
    }

    function harvest(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        uint256 reward = StakingLib.pendingRewards(s, collection, _msgSender(), tokenId, numberOfBlocksPerRewardUnit);
        if (reward == 0) return;
        uint256 feeRate = initialHarvestBurnFeeRate;
        uint256 burnAmt = (reward * feeRate) / 100;
        _mint(_msgSender(), reward);
        if (burnAmt > 0) {
            _burn(_msgSender(), burnAmt);
            burnedCatalystByAddress[_msgSender()] += burnAmt;
            lastBurnBlock[_msgSender()] = block.number;
            if (!isParticipating[_msgSender()]) {
                isParticipating[_msgSender()] = true;
                participatingWallets.push(_msgSender());
            }
        }
        StakingLib.updateLastHarvest(s, collection, _msgSender(), tokenId);
        emit RewardsHarvested(_msgSender(), collection, reward - burnAmt, burnAmt);
    }

    // ------------------------
    // Registration
    // ------------------------
    function registerCollection(address collection, uint256 declaredMaxSupply) external nonReentrant whenNotPaused {
        if (collection == address(0)) revert ZeroAddress();
        if (registeredIndex[collection] != 0) revert AlreadyExists();
        if (declaredMaxSupply == 0 || declaredMaxSupply > MAX_STAKE_PER_COLLECTION) revert BadParam();

        uint256 baseFee = initialCollectionFee;
        if (balanceOf(_msgSender()) < baseFee) revert InsufficientBalance();
        _splitFeeFromSender(_msgSender(), baseFee);

        StakingLib.initCollection(s, collection, declaredMaxSupply);
        registeredCollections.push(collection);
        registeredIndex[collection] = registeredCollections.length;

        emit CollectionAdded(collection, declaredMaxSupply, baseFee, 0, uint8(CollectionTier.UNVERIFIED));
    }

    // ------------------------
    // Fee split (90/9/1)
    // ------------------------
    function _splitFeeFromSender(address payer, uint256 amount) internal {
        if (amount == 0) revert BadParam();
        uint256 burnAmt = (amount * BURN_BP) / 10000;
        uint256 treasuryAmt = (amount * TREASURY_BP) / 10000;
        uint256 deployerAmt = amount - burnAmt - treasuryAmt;

        if (burnAmt > 0) _burn(payer, burnAmt);
        if (deployerAmt > 0) _transfer(payer, deployerAddress, deployerAmt);
        if (treasuryAmt > 0) {
            _transfer(payer, address(this), treasuryAmt);
            treasuryBalance += treasuryAmt;
            emit TreasuryDeposit(payer, treasuryAmt);
        }
    }

    // ------------------------
    // Treasury withdraw
    // ------------------------
    function withdrawTreasury(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount > treasuryBalance) revert InsufficientBalance();
        treasuryBalance -= amount;
        _transfer(address(this), to, amount);
        emit TreasuryWithdrawal(to, amount);
    }

    // ------------------------
    // Views
    // ------------------------
    function stakingStats() external view returns (
        uint256 totalAll,
        uint256 totalTerm,
        uint256 totalPermanent,
        uint256 remainingGlobal,
        uint256 remainingTerm,
        uint256 remainingPermanent
    ) {
        totalAll = s.totalStakedAll;
        totalTerm = s.totalStakedTerm;
        totalPermanent = s.totalStakedPermanent;
        remainingGlobal = (GLOBAL_CAP > totalAll) ? (GLOBAL_CAP - totalAll) : 0;
        remainingTerm = (TERM_CAP > totalTerm) ? (TERM_CAP - totalTerm) : 0;
        remainingPermanent = (PERM_CAP > totalPermanent) ? (PERM_CAP - totalPermanent) : 0;
    }

    function totalStakedNFTs() external view returns (uint256) { return s.totalStakedNFTsCount; }
    function baseReward() external view returns (uint256) { return s.baseRewardRate; }
    function pendingRewardsView(address collection, address owner, uint256 tokenId) external view returns (uint256) {
        return StakingLib.pendingRewards(s, collection, owner, tokenId, numberOfBlocksPerRewardUnit);
    }

    // ------------------------
    // Governance wrappers (lean)
    // ------------------------
    function propose(GovernanceLib.ProposalType pType, uint8 paramTarget, uint256 newValue, address collectionContext) external whenNotPaused returns (bytes32) {
        return GovernanceLib.createProposal(g, pType, paramTarget, newValue, collectionContext, _msgSender(), block.number);
    }

    function vote(bytes32 id) external whenNotPaused {
        (uint256 weight, address attributedCollection) = _votingWeight(_msgSender());
        if (weight == 0) revert NotEligible();
        GovernanceLib.castVote(g, id, _msgSender(), weight, attributedCollection);
        emit DeployerRecoveryApproved(_msgSender(), uint8(0)); // placeholder event reuse (optional)
    }

    function executeProposal(bytes32 id) external whenNotPaused nonReentrant {
        GovernanceLib.Proposal memory p = GovernanceLib.validateForExecution(g, id);
        GovernanceLib.markExecuted(g, id);

        if (p.pType == GovernanceLib.ProposalType.BASE_REWARD) {
            uint256 old = s.baseRewardRate;
            s.baseRewardRate = (p.newValue > maxBaseRewardRate) ? maxBaseRewardRate : p.newValue;
            emit BaseRewardRateUpdated(old, s.baseRewardRate);
        } else if (p.pType == GovernanceLib.ProposalType.HARVEST_FEE) {
            if (p.newValue > 100) revert FeeTooHigh();
            uint256 old = initialHarvestBurnFeeRate;
            initialHarvestBurnFeeRate = p.newValue;
            emit HarvestFeeUpdated(old, p.newValue);
        } else if (p.pType == GovernanceLib.ProposalType.UNSTAKE_FEE) {
            uint256 old = unstakeBurnFee;
            unstakeBurnFee = p.newValue;
            emit UnstakeFeeUpdated(old, p.newValue);
        } else if (p.pType == GovernanceLib.ProposalType.REGISTRATION_FEE_FALLBACK) {
            uint256 old = collectionRegistrationFee;
            collectionRegistrationFee = p.newValue;
            emit RegistrationFeeUpdated(old, p.newValue);
        } else if (p.pType == GovernanceLib.ProposalType.VOTING_PARAM) {
            uint8 t = p.paramTarget;
            if (t == 0) { uint256 old = g.minVotesRequiredScaled; g.minVotesRequiredScaled = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else if (t == 1) { uint256 old = g.votingDurationBlocks; g.votingDurationBlocks = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else if (t == 2) { if (p.newValue > WEIGHT_SCALE) revert FeeTooHigh(); uint256 old = g.collectionVoteCapPercent; g.collectionVoteCapPercent = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else revert BadParam();
        } else revert BadParam();

        emit ProposalExecuted(id, p.newValue);
    }

    function _votingWeight(address voter) internal view returns (uint256 weight, address attributedCollection) {
        for (uint256 i = 0; i < registeredCollections.length; ++i) {
            address coll = registeredCollections[i];
            uint256[] storage port = s.stakePortfolioByUser[coll][voter];
            if (port.length == 0) continue;
            for (uint256 j = 0; j < port.length; ++j) {
                StakingLib.StakeInfo storage si = s.stakeLog[coll][voter][port[j]];
                if (si.currentlyStaked && block.number >= si.stakeBlock + minStakeAgeForVoting) {
                    return (WEIGHT_SCALE, coll);
                }
            }
        }
        return (0, address(0));
    }

    // ------------------------
    // ERC721 receiver, pause, upgrade
    // ------------------------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ------------------------
    // Utilities & math
    // ------------------------
    function _getDynamicPermanentStakeFee() public view returns (uint256) {
        return initialCollectionFee + (StakingLib.sqrt(s.totalStakedNFTsCount) * feeMultiplier);
    }

    function _getDynamicHarvestBurnFeeRate() public view returns (uint256) {
        if (harvestRateAdjustmentFactor == 0) return initialHarvestBurnFeeRate;
        uint256 userBurn = burnedCatalystByAddress[_msgSender()];
        uint256 adjust = userBurn / harvestRateAdjustmentFactor;
        if (adjust >= initialHarvestBurnFeeRate) return 0;
        return initialHarvestBurnFeeRate - adjust;
    }

    function _calculateRegistrationBaseFee(uint256 declaredSupply) internal view returns (uint256) {
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

    // ------------------------
    // Storage gap
    // ------------------------
    uint256[16] private __gap;
}
