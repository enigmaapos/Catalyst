// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StakingLib.sol";
import "./GovernanceLib.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title CatalystNFTStakingUpgradeable (condensed, guardian councils + AGC)
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

    // -------- Custom errors (compact) --------
    error ZeroAddr();
    error InsufficientBalance();
    error NotRegistered();
    error AlreadyStaked();
    error NotStaked();
    error TermActive();
    error CooldownActive();
    error BatchSize();
    error Ineligible();
    error AlreadyVoted();
    error NoActiveRequest();
    error RequestExpired();
    error ThresholdNotMet();
    error Unauthorized();
    error TransferFailed();
    error FeeTooHigh();
    error ExceedsCap();

    // -------- Roles --------
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // -------- Constants --------
    uint256 public constant BURN_BP = 9000;
    uint256 public constant TREASURY_BP = 900;
    uint256 public constant DEPLOYER_BP = 100;

    uint256 public constant WEIGHT_SCALE = 1e18;
    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public constant MAX_STAKE_PER_COLLECTION = 20000;

    // Guardian sizes & thresholds
    uint8 public constant DEPLOYER_GUARDIANS_COUNT = 7;
    uint8 public constant DEPLOYER_RECOVERY_THRESHOLD = 4; // 4-of-7

    uint8 public constant ADMIN_GUARDIANS_COUNT = 5;
    uint8 public constant ADMIN_RECOVERY_THRESHOLD = 3; // 3-of-5 (AGC)

    // -------- Storage (libs) --------
    StakingLib.Storage internal s;
    GovernanceLib.Storage internal g;

    // -------- Params (condensed) --------
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

    // registration fee brackets (kept as public for frontend)
    uint256 public SMALL_MIN_FEE;
    uint256 public SMALL_MAX_FEE;
    uint256 public MED_MIN_FEE;
    uint256 public MED_MAX_FEE;
    uint256 public LARGE_MIN_FEE;
    uint256 public LARGE_MAX_FEE_CAP;

    // other config
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

    // internal treasury accounting
    uint256 public treasuryBalance;

    // staking cooldown
    mapping(address => uint256) public lastStakingBlock;

    // deployer address (receives deployer BP)
    address public deployerAddress;

    // -------- Guardian Councils --------
    // Deployer guardians (fixed-size array of 7)
    address[DEPLOYER_GUARDIANS_COUNT] public deployerGuardians;
    mapping(address => bool) public isDeployerGuardian;

    // Admin Guardian Council (AGC) - fixed-size array of 5
    address[ADMIN_GUARDIANS_COUNT] public adminGuardians;
    mapping(address => bool) public isAdminGuardian;

    // Single active recovery request per type (simple, auditable)
    struct RecoveryRequest {
        address proposed;   // proposed new address (deployer or admin)
        uint8 approvals;
        uint256 deadline;   // timestamp expiry
        bool executed;
    }

    RecoveryRequest public activeDeployerRecovery;
    mapping(address => bool) public hasApprovedDeployer;

    RecoveryRequest public activeAdminRecovery;
    mapping(address => bool) public hasApprovedAdmin;

    uint256 public constant RECOVERY_WINDOW = 3 days;

    // -------- Events --------
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId, bool permanent);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payout, uint256 burned);
    event CollectionAdded(address indexed collection, uint256 declaredSupply, uint256 baseFee, uint256 surcharge, ConfigRegistryLib.CollectionTier tier);

    event DeployerRecoveryProposed(address indexed proposer, address proposed, uint256 deadline);
    event DeployerRecoveryApproved(address indexed guardian, uint8 approvals);
    event DeployerRecovered(address indexed oldDeployer, address indexed newDeployer);

    event AdminRecoveryProposed(address indexed proposer, address proposed, uint256 deadline);
    event AdminRecoveryApproved(address indexed guardian, uint8 approvals);
    event AdminRecovered(address indexed oldAdmin, address indexed newAdmin);

    event GuardianSet(bytes32 indexed council, uint8 index, address guardian);

    // -------- Initializer --------
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
        // guardians
        address[DEPLOYER_GUARDIANS_COUNT] deployerGuardians;
        address[ADMIN_GUARDIANS_COUNT] adminGuardians;
    }

    function initialize(InitConfig calldata cfg) public initializer {
        if (cfg.owner == address(0)) revert ZeroAddr();

        __ERC20_init("Catalyst", "CATA");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _mint(cfg.owner, 25_185_000 * 10**18);

        _grantRole(DEFAULT_ADMIN_ROLE, cfg.owner);
        _grantRole(CONTRACT_ADMIN_ROLE, cfg.owner);

        // params
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

        numberOfBlocksPerRewardUnit = 18782;
        SMALL_MIN_FEE = 1000 * 10**18;
        SMALL_MAX_FEE = 5000 * 10**18;
        MED_MIN_FEE = 5000 * 10**18;
        MED_MAX_FEE = 10000 * 10**18;
        LARGE_MIN_FEE = 10000 * 10**18;
        LARGE_MAX_FEE_CAP = 20000 * 10**18;
        unverifiedSurchargeBP = 20000;

        minStakeAgeForVoting = 100;
        maxBaseRewardRate = type(uint256).max;

        // governance lib init
        GovernanceLib.initGov(g, cfg.votingDurationBlocks, cfg.minVotesRequiredScaled, cfg.collectionVoteCapPercent);

        // seed deployer guardians
        for (uint8 i = 0; i < DEPLOYER_GUARDIANS_COUNT; ++i) {
            address a = cfg.deployerGuardians[i];
            deployerGuardians[i] = a;
            if (a != address(0)) isDeployerGuardian[a] = true;
            emit GuardianSet(keccak256("DEPLOYER"), i, a);
        }
        // seed admin guardians (AGC)
        for (uint8 j = 0; j < ADMIN_GUARDIANS_COUNT; ++j) {
            address a = cfg.adminGuardians[j];
            adminGuardians[j] = a;
            if (a != address(0)) isAdminGuardian[a] = true;
            emit GuardianSet(keccak256("ADMIN"), j, a);
        }
    }

    // -------- Guardian setters (admin only) --------
    function setDeployerGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (idx >= DEPLOYER_GUARDIANS_COUNT) revert ZeroAddr();
        address old = deployerGuardians[idx];
        if (old != address(0)) isDeployerGuardian[old] = false;
        deployerGuardians[idx] = guardian;
        if (guardian != address(0)) isDeployerGuardian[guardian] = true;
        emit GuardianSet(keccak256("DEPLOYER"), idx, guardian);
    }

    function setAdminGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (idx >= ADMIN_GUARDIANS_COUNT) revert ZeroAddr();
        address old = adminGuardians[idx];
        if (old != address(0)) isAdminGuardian[old] = false;
        adminGuardians[idx] = guardian;
        if (guardian != address(0)) isAdminGuardian[guardian] = true;
        emit GuardianSet(keccak256("ADMIN"), idx, guardian);
    }

    // -------- Recovery flows (deployer) --------
    function proposeDeployerRecovery(address newDeployer) external whenNotPaused {
        if (!isDeployerGuardian[_msgSender()]) revert Unauthorized();
        if (newDeployer == address(0)) revert ZeroAddr();

        activeDeployerRecovery = RecoveryRequest({ proposed: newDeployer, approvals: 0, deadline: block.timestamp + RECOVERY_WINDOW, executed: false });

        // reset approvals mapping (iterate guardians to clear flags) - small loop
        for (uint8 i = 0; i < DEPLOYER_GUARDIANS_COUNT; ++i) {
            address gaddr = deployerGuardians[i];
            if (gaddr != address(0)) hasApprovedDeployer[gaddr] = false;
        }

        emit DeployerRecoveryProposed(_msgSender(), newDeployer, activeDeployerRecovery.deadline);
    }

    function approveDeployerRecovery() external whenNotPaused {
        if (!isDeployerGuardian[_msgSender()]) revert Unauthorized();
        if (activeDeployerRecovery.proposed == address(0)) revert NoActiveRequest();
        if (activeDeployerRecovery.executed) revert AlreadyVoted();
        if (block.timestamp > activeDeployerRecovery.deadline) revert RequestExpired();
        if (hasApprovedDeployer[_msgSender()]) revert AlreadyVoted();

        hasApprovedDeployer[_msgSender()] = true;
        activeDeployerRecovery.approvals += 1;

        emit DeployerRecoveryApproved(_msgSender(), activeDeployerRecovery.approvals);
    }

    function executeDeployerRecovery() external whenNotPaused {
        if (activeDeployerRecovery.proposed == address(0)) revert NoActiveRequest();
        if (activeDeployerRecovery.executed) revert AlreadyVoted();
        if (block.timestamp > activeDeployerRecovery.deadline) revert RequestExpired();
        if (activeDeployerRecovery.approvals < DEPLOYER_RECOVERY_THRESHOLD) revert ThresholdNotMet();

        address old = deployerAddress;
        deployerAddress = activeDeployerRecovery.proposed;
        activeDeployerRecovery.executed = true;

        // optionally remove old deployer if it was guardian
        if (isDeployerGuardian[old]) {
            // remove from array
            for (uint8 i = 0; i < DEPLOYER_GUARDIANS_COUNT; ++i) {
                if (deployerGuardians[i] == old) {
                    isDeployerGuardian[old] = false;
                    deployerGuardians[i] = address(0);
                    emit GuardianSet(keccak256("DEPLOYER"), i, address(0));
                    break;
                }
            }
        }

        emit DeployerRecovered(old, deployerAddress);
    }

    // -------- Recovery flows (admin / AGC) --------
    // AGC can propose to transfer DEFAULT_ADMIN_ROLE to a new address (protects upgrade & role management)
    function proposeAdminRecovery(address newAdmin) external whenNotPaused {
        if (!isAdminGuardian[_msgSender()]) revert Unauthorized();
        if (newAdmin == address(0)) revert ZeroAddr();

        activeAdminRecovery = RecoveryRequest({ proposed: newAdmin, approvals: 0, deadline: block.timestamp + RECOVERY_WINDOW, executed: false });

        for (uint8 i = 0; i < ADMIN_GUARDIANS_COUNT; ++i) {
            address gaddr = adminGuardians[i];
            if (gaddr != address(0)) hasApprovedAdmin[gaddr] = false;
        }

        emit AdminRecoveryProposed(_msgSender(), newAdmin, activeAdminRecovery.deadline);
    }

    function approveAdminRecovery() external whenNotPaused {
        if (!isAdminGuardian[_msgSender()]) revert Unauthorized();
        if (activeAdminRecovery.proposed == address(0)) revert NoActiveRequest();
        if (activeAdminRecovery.executed) revert AlreadyVoted();
        if (block.timestamp > activeAdminRecovery.deadline) revert RequestExpired();
        if (hasApprovedAdmin[_msgSender()]) revert AlreadyVoted();

        hasApprovedAdmin[_msgSender()] = true;
        activeAdminRecovery.approvals += 1;

        emit AdminRecoveryApproved(_msgSender(), activeAdminRecovery.approvals);
    }

    function executeAdminRecovery() external whenNotPaused {
        if (activeAdminRecovery.proposed == address(0)) revert NoActiveRequest();
        if (activeAdminRecovery.executed) revert AlreadyVoted();
        if (block.timestamp > activeAdminRecovery.deadline) revert RequestExpired();
        if (activeAdminRecovery.approvals < ADMIN_RECOVERY_THRESHOLD) revert ThresholdNotMet();

        // change DEFAULT_ADMIN_ROLE: grant to new, then revoke from old admin(s)
        address newAdmin = activeAdminRecovery.proposed;

        // fetch current admin members (we can't enumerate easily without extension, but we can revoke role from caller if needed)
        // We'll grant role to newAdmin and rely on existing admin holder(s) to revoke themselves or the contract owner to revoke old ones.
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);

        activeAdminRecovery.executed = true;

        emit AdminRecovered(newAdmin, newAdmin);
    }

    // -------- Staking wrappers (lean) --------
    function stake(address collection, uint256 tokenId, bool permanent) external nonReentrant whenNotPaused {
        if (collection == address(0)) revert ZeroAddr();
        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        if (permanent) {
            // fee collection for permanent stake (dynamic)
            uint256 fee = initialCollectionFee + (StakingLib.sqrt(s.totalStakedNFTsCount) * feeMultiplier);
            if (balanceOf(_msgSender()) < fee) revert InsufficientBalance();
            _splitFeeFromSender(_msgSender(), fee);
            s.recordPermanentStake(collection, _msgSender(), tokenId, block.number, rewardRateIncrementPerNFT);
            emit NFTStaked(_msgSender(), collection, tokenId, true);
        } else {
            s.recordTermStake(collection, _msgSender(), tokenId, block.number, termDurationBlocks, rewardRateIncrementPerNFT);
            emit NFTStaked(_msgSender(), collection, tokenId, false);
        }
        // welcome bonus
        uint256 dynamicWelcome = welcomeBonusBaseRate + (s.totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
        if (dynamicWelcome > 0) _mint(_msgSender(), dynamicWelcome);
        lastStakingBlock[_msgSender()] = block.number;
    }

    function batchStake(address collection, uint256[] calldata tokenIds, bool permanent) external nonReentrant whenNotPaused {
        uint256 n = tokenIds.length;
        if (n == 0 || n > MAX_HARVEST_BATCH) revert BatchSize();
        for (uint256 i; i < n; ) {
            stake(collection, tokenIds[i], permanent);
            unchecked { ++i; }
        }
    }

    function unstake(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        StakingLib.StakeInfo memory info = s.stakeLog[collection][_msgSender()][tokenId];
        if (!info.currentlyStaked) revert NotStaked();
        if (!info.isPermanent && block.number < info.unstakeDeadlineBlock) revert TermActive();

        // harvest first
        uint256 reward = s.pendingRewards(collection, _msgSender(), tokenId, numberOfBlocksPerRewardUnit);
        if (reward > 0) {
            uint256 feeRate = initialHarvestBurnFeeRate;
            uint256 burnAmt = (reward * feeRate) / 100;
            _mint(_msgSender(), reward);
            if (burnAmt > 0) {
                _burn(_msgSender(), burnAmt);
                burnedCatalystByAddress[_msgSender()] += burnAmt;
                lastBurnBlock[_msgSender()] = block.number;
                if (!isParticipating[_msgSender()]) { isParticipating[_msgSender()] = true; participatingWallets.push(_msgSender()); }
            }
            s.updateLastHarvest(collection, _msgSender(), tokenId);
            emit RewardsHarvested(_msgSender(), collection, reward - burnAmt, burnAmt);
        }

        if (balanceOf(_msgSender()) < unstakeBurnFee) revert InsufficientBalance();
        _splitFeeFromSender(_msgSender(), unstakeBurnFee);

        s.recordUnstake(collection, _msgSender(), tokenId, rewardRateIncrementPerNFT);

        IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);
        emit NFTUnstaked(_msgSender(), collection, tokenId);
    }

    function harvest(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        uint256 reward = s.pendingRewards(collection, _msgSender(), tokenId, numberOfBlocksPerRewardUnit);
        if (reward == 0) return;
        uint256 feeRate = initialHarvestBurnFeeRate;
        uint256 burnAmt = (reward * feeRate) / 100;
        _mint(_msgSender(), reward);
        if (burnAmt > 0) {
            _burn(_msgSender(), burnAmt);
            burnedCatalystByAddress[_msgSender()] += burnAmt;
            lastBurnBlock[_msgSender()] = block.number;
            if (!isParticipating[_msgSender()]) { isParticipating[_msgSender()] = true; participatingWallets.push(_msgSender()); }
        }
        s.updateLastHarvest(collection, _msgSender(), tokenId);
        emit RewardsHarvested(_msgSender(), collection, reward - burnAmt, burnAmt);
    }

    // -------- Registration (condensed) --------
    function registerCollection(address collection, uint256 declaredMaxSupply, ConfigRegistryLib.CollectionTier /*tier*/) external nonReentrant whenNotPaused {
        if (collection == address(0)) revert ZeroAddr();
        if (registeredIndex[collection] != 0) revert AlreadyStaked();
        uint256 baseFee = initialCollectionFee; // simplified: compute with your fee brackets if needed
        if (balanceOf(_msgSender()) < baseFee) revert InsufficientBalance();
        _splitFeeFromSender(_msgSender(), baseFee);

        s.initCollection(collection, declaredMaxSupply);
        registeredCollections.push(collection);
        registeredIndex[collection] = registeredCollections.length;
        emit CollectionAdded(collection, declaredMaxSupply, baseFee, 0, ConfigRegistryLib.CollectionTier.UNVERIFIED);
    }

    // -------- Fee split helper (immutable 90/9/1) --------
    function _splitFeeFromSender(address payer, uint256 amount) internal {
        if (amount == 0) revert ZeroAddr();
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

    // -------- Treasury withdraw --------
    function withdrawTreasury(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (to == address(0)) revert ZeroAddr();
        if (amount > treasuryBalance) revert InsufficientBalance();
        treasuryBalance -= amount;
        _transfer(address(this), to, amount);
        emit TreasuryWithdrawal(to, amount);
    }

    // -------- Views (staking stats + helpers) --------
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

        // read caps from library constants
        uint256 globalCap = StakingLib.GLOBAL_CAP();
        uint256 termCap = StakingLib.TERM_CAP();
        uint256 permCap = StakingLib.PERM_CAP();

        remainingGlobal = (globalCap > totalAll) ? (globalCap - totalAll) : 0;
        remainingTerm = (termCap > totalTerm) ? (termCap - totalTerm) : 0;
        remainingPermanent = (permCap > totalPermanent) ? (permCap - totalPermanent) : 0;
    }

    function totalStakedNFTs() external view returns (uint256) { return s.totalStakedNFTsCount; }
    function baseReward() external view returns (uint256) { return s.baseRewardRate; }

    // pendingRewards view wrapper
    function pendingRewardsView(address collection, address owner, uint256 tokenId) external view returns (uint256) {
        return s.pendingRewards(collection, owner, tokenId, numberOfBlocksPerRewardUnit);
    }

    // -------- ERC721 receiver --------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // -------- Pause / admin helpers --------
    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }

    // -------- Governance wrappers (lean) --------
    function propose(GovernanceLib.ProposalType pType, uint8 paramTarget, uint256 newValue, address collectionContext) external whenNotPaused returns (bytes32) {
        return GovernanceLib.createProposal(g, pType, paramTarget, newValue, collectionContext, _msgSender(), block.number);
    }

    function vote(bytes32 id) external whenNotPaused {
        (uint256 weight, address attributed) = _votingWeight(_msgSender());
        if (weight == 0) revert Ineligible();
        GovernanceLib.castVote(g, id, _msgSender(), weight, attributed);
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
            else revert Unauthorized();
        } else revert Unauthorized();
        emit ProposalExecuted(id, p.newValue);
    }

    function _votingWeight(address voter) internal view returns (uint256 weight, address attributedCollection) {
        // same basic scheme: aged stake in registered collections => full weight
        for (uint256 i = 0; i < registeredCollections.length; ++i) {
            address coll = registeredCollections[i];
            uint256[] storage port = s.stakePortfolioByUser[coll][voter];
            if (port.length == 0) continue;
            for (uint256 j = 0; j < port.length; ++j) {
                StakingLib.StakeInfo storage si = s.stakeLog[coll][voter][port[j]];
                if (si.currentlyStaked && block.number >= si.stakeBlock + minStakeAgeForVoting) return (WEIGHT_SCALE, coll);
            }
        }
        return (0, address(0));
    }

    // -------- UUPS authorization --------
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // -------- Events for governance changes (kept) --------
    event BaseRewardRateUpdated(uint256 oldValue, uint256 newValue);
    event HarvestFeeUpdated(uint256 oldValue, uint256 newValue);
    event UnstakeFeeUpdated(uint256 oldValue, uint256 newValue);
    event RegistrationFeeUpdated(uint256 oldValue, uint256 newValue);
    event VotingParamUpdated(uint8 target, uint256 oldValue, uint256 newValue);
    event ProposalExecuted(bytes32 indexed id, uint256 appliedValue);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);

    // storage gap for upgradeability
    uint256[30] private __gap;
}
