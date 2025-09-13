// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StakingLib.sol";
import "./GovernanceLib.sol";
import "./BluechipLib.sol";

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
    uint256 public constant BURN_BP = 9000;      // 90%
    uint256 public constant TREASURY_BP = 900;   // 9%
    uint256 public constant DEPLOYER_BP = 100;   // 1%
    uint256 public constant BP_DENOM = 10000;

    uint256 public constant GLOBAL_CAP = StakingLib.GLOBAL_CAP;
    uint256 public constant TERM_CAP = StakingLib.TERM_CAP;
    uint256 public constant PERM_CAP = StakingLib.PERM_CAP;

    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public constant MAX_STAKE_PER_COLLECTION = 20_000;
    uint256 public constant WEIGHT_SCALE = 1e18;

    uint8 public constant DEPLOYER_GCOUNT = 7;
    uint8 public constant DEPLOYER_THRESHOLD = 5;
    uint8 public constant ADMIN_GCOUNT = 7;
    uint8 public constant ADMIN_THRESHOLD = 5;

    uint256 public constant RECOVERY_WINDOW = 3 days;

    // -------- Library storage --------
    StakingLib.Storage internal s;
    GovernanceLib.Storage internal g;
    BluechipLib.Storage internal b;

    // -------- Protocol params --------
    uint256 public numberOfBlocksPerRewardUnit;
    uint256 public termDurationBlocks;
    uint256 public stakingCooldownBlocks;
    uint256 public rewardRateIncrementPerNFT;
    uint256 public initialHarvestBurnFeeRate;
    uint256 public unstakeBurnFee;
    uint256 public collectionRegistrationFee;

    // treasury + deployer
    address public treasuryAddress;
    address public deployerAddress;
    uint256 public treasuryBalance;

    // governance helpers
    uint256 public minStakeAgeForVoting;
    uint256 public maxBaseRewardRate;

    // registration enumeration
    address[] public registeredCollections;
    mapping(address => uint256) public registeredIndex; // index+1 (0==not registered)

    // burner bookkeeping
    mapping(address => uint256) public burnedCatalystByAddress;

    // user staking cooldown
    mapping(address => uint256) public lastStakingBlock;

    // guard / guardian state
    address[DEPLOYER_GCOUNT] public deployerGuardians;
    mapping(address => bool) public isDeployerGuardian;

    address[ADMIN_GCOUNT] public adminGuardians;
    mapping(address => bool) public isAdminGuardian;

    struct RecoveryRequest {
        address proposed;
        uint8 approvals;
        uint256 deadline;
        bool executed;
    }

    RecoveryRequest public deployerRecovery;
    mapping(address => bool) public deployerHasApproved;

    RecoveryRequest public adminRecovery;
    mapping(address => bool) public adminHasApproved;

    // -------- Events (kept) --------
	event BluechipCollectionSet(address indexed collection, bool isBluechip);
    event CollectionAdded(address indexed collection, uint256 declaredSupply, uint256 paid);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId, bool permanent);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 gross, uint256 burned);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);

    event GuardianSet(bytes32 council, uint8 idx, address guardian);
    event DeployerRecoveryProposed(address indexed proposer, address proposed, uint256 deadline);
    event DeployerRecoveryApproved(address indexed guardian, uint8 approvals);
    event DeployerRecovered(address indexed oldDeployer, address indexed newDeployer);

    event AdminRecoveryProposed(address indexed proposer, address proposed, uint256 deadline);
    event AdminRecoveryApproved(address indexed guardian, uint8 approvals);
    event AdminRecovered(address indexed newAdmin);

    event BaseRewardRateUpdated(uint256 oldValue, uint256 newValue);
    event HarvestFeeUpdated(uint256 oldValue, uint256 newValue);
    event UnstakeFeeUpdated(uint256 oldValue, uint256 newValue);
    event RegistrationFeeUpdated(uint256 oldValue, uint256 newValue);
    event VotingParamUpdated(uint8 target, uint256 oldValue, uint256 newValue);
    event ProposalExecuted(bytes32 indexed id, uint256 appliedValue);

    // -------- Initializer --------
    struct InitConfig {
        address owner;
        // fees & rewards
        uint256 rewardRateIncrementPerNFT;
        uint256 initialHarvestBurnFeeRate;  // 0..100 (percentage)
        uint256 unstakeBurnFee;             // flat CATA
        uint256 termDurationBlocks;
        uint256 numberOfBlocksPerRewardUnit;
        uint256 collectionRegistrationFee;
        uint256 stakingCooldownBlocks;
        // governance
        uint256 votingDurationBlocks;
        uint256 minVotesRequiredScaled;
        uint256 collectionVoteCapPercent;   // 0..100
        uint256 minStakeAgeForVoting;
        uint256 maxBaseRewardRate;          // safety clamp
        // guardians
        address[DEPLOYER_GCOUNT] deployerGuardians;
        address[ADMIN_GCOUNT] adminGuardians;
        // bluechip
        uint256 bluechipWalletFee;          // per-wallet (Option A)
    }

    /// @notice initializer
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

        // Setup governance
        GovernanceLib.initGov(
            g,
            cfg.votingDurationBlocks,
            cfg.minVotesRequiredScaled,
            cfg.collectionVoteCapPercent
        );

        // Seed guardians (disallow duplicates)
        for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
            address a = cfg.deployerGuardians[i];
            if (a == address(0)) {
                deployerGuardians[i] = address(0);
                emit GuardianSet(keccak256("DEPLOYER"), i, address(0));
                continue;
            }
            // duplicate check
            for (uint8 k = 0; k < i; ++k) {
                if (deployerGuardians[k] == a) revert DuplicateGuardian();
            }
            deployerGuardians[i] = a;
            isDeployerGuardian[a] = true;
            emit GuardianSet(keccak256("DEPLOYER"), i, a);
        }
        for (uint8 j = 0; j < ADMIN_GCOUNT; ++j) {
            address a = cfg.adminGuardians[j];
            if (a == address(0)) {
                adminGuardians[j] = address(0);
                emit GuardianSet(keccak256("ADMIN"), j, address(0));
                continue;
            }
            for (uint8 k = 0; k < j; ++k) {
                if (adminGuardians[k] == a) revert DuplicateGuardian();
            }
            adminGuardians[j] = a;
            isAdminGuardian[a] = true;
            emit GuardianSet(keccak256("ADMIN"), j, a);
        }

        // Blue-chip config (per-wallet fee)
        b.bluechipWalletFee = cfg.bluechipWalletFee;

        // optional genesis mint
        _mint(cfg.owner, 100_000_000 * 1e18);
    }

    // -------- Modifiers --------
    modifier onlyDeployerGuardian() {
        if (!isDeployerGuardian[_msgSender()]) revert Unauthorized();
        _;
    }
    modifier onlyAdminGuardian() {
        if (!isAdminGuardian[_msgSender()]) revert Unauthorized();
        _;
    }
    modifier onlyContractAdminRole() {
        if (!hasRole(CONTRACT_ADMIN_ROLE, _msgSender())) revert Unauthorized();
        _;
    }

/// @dev ensures provided collection was registered previously
modifier onlyRegistered(address collection) {
    if (registeredIndex[collection] == 0) revert NotRegistered();
    _;
}

    // -------- Guardians: admin setters (only DEFAULT_ADMIN_ROLE allowed) --------
    function setDeployerGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (idx >= DEPLOYER_GCOUNT) revert BadParam();
        if (guardian == address(0)) revert ZeroAddress();
        // prevent duplicate
        for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
            if (deployerGuardians[i] == guardian) revert DuplicateGuardian();
        }
        address old = deployerGuardians[idx];
        if (old != address(0)) isDeployerGuardian[old] = false;
        deployerGuardians[idx] = guardian;
        isDeployerGuardian[guardian] = true;
        emit GuardianSet(keccak256("DEPLOYER"), idx, guardian);
    }

    function setAdminGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (idx >= ADMIN_GCOUNT) revert BadParam();
        if (guardian == address(0)) revert ZeroAddress();
        for (uint8 i = 0; i < ADMIN_GCOUNT; ++i) {
            if (adminGuardians[i] == guardian) revert DuplicateGuardian();
        }
        address old = adminGuardians[idx];
        if (old != address(0)) isAdminGuardian[old] = false;
        adminGuardians[idx] = guardian;
        isAdminGuardian[guardian] = true;
        emit GuardianSet(keccak256("ADMIN"), idx, guardian);
    }

    // -------- Deployer recovery (7:5) --------
    function proposeDeployerRecovery(address newDeployer) external whenNotPaused onlyDeployerGuardian {
        if (newDeployer == address(0)) revert ZeroAddress();

        deployerRecovery = RecoveryRequest({
            proposed: newDeployer,
            approvals: 0,
            deadline: block.timestamp + RECOVERY_WINDOW,
            executed: false
        });

        // reset approvals mapping for guard set
        for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
            address gaddr = deployerGuardians[i];
            if (gaddr != address(0)) deployerHasApproved[gaddr] = false;
        }

        emit DeployerRecoveryProposed(_msgSender(), newDeployer, deployerRecovery.deadline);
    }

    function approveDeployerRecovery() external whenNotPaused onlyDeployerGuardian {
        if (deployerRecovery.proposed == address(0)) revert NoRequest();
        if (block.timestamp > deployerRecovery.deadline) revert Expired();
        if (deployerRecovery.executed) revert AlreadyApproved();
        if (deployerHasApproved[_msgSender()]) revert AlreadyApproved();

        deployerHasApproved[_msgSender()] = true;
        deployerRecovery.approvals += 1;
        emit DeployerRecoveryApproved(_msgSender(), deployerRecovery.approvals);
    }

    function executeDeployerRecovery() external whenNotPaused {
        if (deployerRecovery.proposed == address(0)) revert NoRequest();
        if (block.timestamp > deployerRecovery.deadline) revert Expired();
        if (deployerRecovery.executed) revert AlreadyApproved();
        if (deployerRecovery.approvals < DEPLOYER_THRESHOLD) revert Threshold();

        address old = deployerAddress;
        deployerAddress = deployerRecovery.proposed;
        deployerRecovery.executed = true;

        // Optional: remove old if present in council
        if (isDeployerGuardian[old]) {
            for (uint8 i = 0; i < DEPLOYER_GCOUNT; ++i) {
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

    // -------- Admin recovery (7:5) --------
    function proposeAdminRecovery(address newAdmin) external whenNotPaused onlyAdminGuardian {
        if (newAdmin == address(0)) revert ZeroAddress();

        adminRecovery = RecoveryRequest({
            proposed: newAdmin,
            approvals: 0,
            deadline: block.timestamp + RECOVERY_WINDOW,
            executed: false
        });

        for (uint8 i = 0; i < ADMIN_GCOUNT; ++i) {
            address gaddr = adminGuardians[i];
            if (gaddr != address(0)) adminHasApproved[gaddr] = false;
        }

        emit AdminRecoveryProposed(_msgSender(), newAdmin, adminRecovery.deadline);
    }

    function approveAdminRecovery() external whenNotPaused onlyAdminGuardian {
        if (adminRecovery.proposed == address(0)) revert NoRequest();
        if (block.timestamp > adminRecovery.deadline) revert Expired();
        if (adminRecovery.executed) revert AlreadyApproved();
        if (adminHasApproved[_msgSender()]) revert AlreadyApproved();

        adminHasApproved[_msgSender()] = true;
        adminRecovery.approvals += 1;
        emit AdminRecoveryApproved(_msgSender(), adminRecovery.approvals);
    }

    function executeAdminRecovery() external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adminRecovery.proposed == address(0)) revert NoRequest();
        if (block.timestamp > adminRecovery.deadline) revert Expired();
        if (adminRecovery.executed) revert AlreadyApproved();
        if (adminRecovery.approvals < ADMIN_THRESHOLD) revert Threshold();

        _grantRole(DEFAULT_ADMIN_ROLE, adminRecovery.proposed);
        adminRecovery.executed = true;

        emit AdminRecovered(adminRecovery.proposed);
    }

    // -------- Registration (permissionless with fee guard) --------
    function registerCollection(address collection, uint256 declaredMaxSupply) external whenNotPaused nonReentrant {
        if (collection == address(0)) revert ZeroAddress();
        if (registeredIndex[collection] != 0) revert AlreadyExists();
        if (declaredMaxSupply == 0 || declaredMaxSupply > MAX_STAKE_PER_COLLECTION) revert BadParam();

        uint256 fee = collectionRegistrationFee;
        if (fee > 0) _splitFeeFromSender(_msgSender(), fee);

        s.initCollection(collection, declaredMaxSupply);
        registeredCollections.push(collection);
        registeredIndex[collection] = registeredCollections.length;

        emit CollectionAdded(collection, declaredMaxSupply, fee);
    }

    // -------- Custodial Staking --------
    modifier notInCooldown() {
        if (block.number < lastStakingBlock[_msgSender()] + stakingCooldownBlocks) revert Cooldown();
        _;
    }

    function stake(address collection, uint256 tokenId, bool permanent)
    public
    whenNotPaused
    nonReentrant
    notInCooldown
{
    if (collection == address(0)) revert ZeroAddress();
    IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

    if (permanent) {
        s.recordPermanentStake(
            collection,
            _msgSender(),
            tokenId,
            block.number,
            rewardRateIncrementPerNFT
        );
    } else {
        s.recordTermStake(
            collection,
            _msgSender(),
            tokenId,
            block.number,
            termDurationBlocks,
            rewardRateIncrementPerNFT
        );
    }

    // ✅ increment per-collection counter
    s.collectionTotalStaked[collection] += 1;

    lastStakingBlock[_msgSender()] = block.number;
    emit NFTStaked(_msgSender(), collection, tokenId, permanent);
}

    function batchStake(address collection, uint256[] calldata tokenIds, bool permanent) external whenNotPaused {
        uint256 n = tokenIds.length;
        if (n == 0 || n > MAX_HARVEST_BATCH) revert BatchTooLarge();
        for (uint256 i = 0; i < n; ++i) {
            stake(collection, tokenIds[i], permanent);
        }
    }

    function harvest(address collection, uint256 tokenId) external whenNotPaused nonReentrant {
        uint256 reward = s.pendingRewards(collection, _msgSender(), tokenId, numberOfBlocksPerRewardUnit);
        if (reward == 0) return;

        uint256 burnAmt = (reward * initialHarvestBurnFeeRate) / 100;
        _mint(_msgSender(), reward);
        if (burnAmt > 0) {
            _burn(_msgSender(), burnAmt);
            burnedCatalystByAddress[_msgSender()] += burnAmt;
        }
        s.updateLastHarvest(collection, _msgSender(), tokenId);

        emit RewardsHarvested(_msgSender(), collection, reward, burnAmt);
    }

    function unstake(address collection, uint256 tokenId) external whenNotPaused nonReentrant {
    StakingLib.StakeInfo memory info = s.stakeLog[collection][_msgSender()][tokenId];
    if (!info.currentlyStaked) revert NotStaked();
    if (!info.isPermanent && block.number < info.unstakeDeadlineBlock) revert TermNotExpired();

        // harvest pending first
        uint256 reward = s.pendingRewards(collection, _msgSender(), tokenId, numberOfBlocksPerRewardUnit);
        if (reward > 0) {
            uint256 burnAmt = (reward * initialHarvestBurnFeeRate) / 100;
            _mint(_msgSender(), reward);
            if (burnAmt > 0) {
                _burn(_msgSender(), burnAmt);
                burnedCatalystByAddress[_msgSender()] += burnAmt;
            }
            s.updateLastHarvest(collection, _msgSender(), tokenId);
            emit RewardsHarvested(_msgSender(), collection, reward, burnAmt);
        }

        // unstake burn fee (flat)
        if (unstakeBurnFee > 0) {
            if (balanceOf(_msgSender()) < unstakeBurnFee) revert Insufficient();
            _splitFeeFromSender(_msgSender(), unstakeBurnFee);
        }

            s.recordUnstake(collection, _msgSender(), tokenId, rewardRateIncrementPerNFT);

    // ✅ decrement counter
    if (s.collectionTotalStaked[collection] > 0) {
        s.collectionTotalStaked[collection] -= 1;
    }

    IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);
    emit NFTUnstaked(_msgSender(), collection, tokenId);
}

    // -------- Blue-chip (non-custodial) --------
function setBluechipCollection(address collection, bool isBluechip)
    external
    onlyRole(CONTRACT_ADMIN_ROLE)
    whenNotPaused
    onlyRegistered(collection)
{
    b.isBluechipCollection[collection] = isBluechip;
    emit BluechipCollectionSet(collection, isBluechip); // ✅ now works
}

    function enrollBluechip() external whenNotPaused nonReentrant {
        address wallet = _msgSender();
        // check already enrolled global slot
        if (b.bluechipWallets[address(0)][wallet].enrolled) revert AlreadyEnrolled();
        uint256 fee = b.bluechipWalletFee;
        // fee splitter will revert if insufficient balance
        BluechipLib.enroll(b, address(0), wallet, block.number, fee, _splitFeeFromSender);
    }

    function harvestBluechip(address collection) external whenNotPaused nonReentrant {
        if (!b.isBluechipCollection[collection]) revert Ineligible();
        require(IERC721(collection).balanceOf(_msgSender()) > 0, "no token");
        // compute reward (simple model: use baseRewardRate & blocks since last enrollment/harvest)
        // For simplicity use baseRewardRate / total staked as approximation (same as custodial)
        // main contract retains mint logic and bookkeeping for bluechip harvests if required
        // Here we delegate to BluechipLib for checks, then mint externally:
        BluechipLib.harvest(b, collection, _msgSender(), block.number, s.baseRewardRate, numberOfBlocksPerRewardUnit, _mintReward);
        // Note: ensure BluechipLib.harvest triggers appropriate mint or inform main contract to mint
    }

    // -------- Governance wrappers --------
    function propose(
        GovernanceLib.ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collectionContext
    ) external whenNotPaused returns (bytes32) {
        (uint256 weight,) = _votingWeight(_msgSender());
        if (weight == 0) revert Ineligible();

        return GovernanceLib.createProposal(
            g,
            pType,
            paramTarget,
            newValue,
            collectionContext,
            _msgSender(),
            block.number
        );
    }

    function vote(bytes32 id) external whenNotPaused {
        (uint256 weight, address attributedCollection) = _votingWeight(_msgSender());
        if (weight == 0) revert Ineligible();
        GovernanceLib.castVote(g, id, _msgSender(), weight, attributedCollection);
    }

    function executeProposal(bytes32 id) external whenNotPaused nonReentrant {
        GovernanceLib.Proposal memory p = GovernanceLib.validateForExecution(g, id);
        GovernanceLib.markExecuted(g, id);

        if (p.pType == GovernanceLib.ProposalType.BASE_REWARD) {
            uint256 old = s.baseRewardRate;
            s.baseRewardRate = p.newValue > maxBaseRewardRate ? maxBaseRewardRate : p.newValue;
            emit BaseRewardRateUpdated(old, s.baseRewardRate);
        } else if (p.pType == GovernanceLib.ProposalType.HARVEST_FEE) {
            uint256 old = initialHarvestBurnFeeRate;
            initialHarvestBurnFeeRate = p.newValue; // expect 0..100
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
            else if (t == 2) { uint256 old = g.collectionVoteCapPercent; g.collectionVoteCapPercent = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else revert BadParam();
        } else if (p.pType == GovernanceLib.ProposalType.TIER_UPGRADE) {
            // hook for future upgrades
        } else {
            revert BadParam();
        }

        emit ProposalExecuted(id, p.newValue);
    }

    function _votingWeight(address voter) internal view returns (uint256 weight, address attributedCollection) {
        // 1) Any active stake older than minStakeAge gives full weight
        uint256 len = registeredCollections.length;
        for (uint256 i = 0; i < len; ++i) {
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
        // 2) Or: enrolled blue-chip + currently owns at least one token in a flagged collection
        for (uint256 i = 0; i < len; ++i) {
            address coll = registeredCollections[i];
            if (b.isBluechipCollection[coll] && (b.bluechipWallets[coll][voter].enrolled || b.bluechipWallets[address(0)][voter].enrolled)) {
                if (IERC721(coll).balanceOf(voter) > 0) {
                    return (WEIGHT_SCALE, coll);
                }
            }
        }
        return (0, address(0));
    }

    // -------- Fee split, treasury, helpers --------
    function _splitFeeFromSender(address payer, uint256 amount) internal {
        if (amount == 0) return;
        // require that payer has enough balance (ERC20 balance check using this contract's ERC20 state)
        if (balanceOf(payer) < amount) revert Insufficient();
        uint256 burnAmt = (amount * BURN_BP) / BP_DENOM;
        uint256 treasuryAmt = (amount * TREASURY_BP) / BP_DENOM;
        uint256 deployerAmt = amount - burnAmt - treasuryAmt;

        _burn(payer, burnAmt);
        if (treasuryAmt > 0) {
            _transfer(payer, address(this), treasuryAmt);
            treasuryBalance += treasuryAmt;
            emit TreasuryDeposit(payer, treasuryAmt);
        }
        if (deployerAmt > 0) {
            _transfer(payer, deployerAddress, deployerAmt);
        }
    }

    function withdrawTreasury(address to, uint256 amount)
        external
        onlyRole(CONTRACT_ADMIN_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount > treasuryBalance) revert Insufficient();
        treasuryBalance -= amount;
        _transfer(address(this), to, amount);
        emit TreasuryWithdrawal(to, amount);
    }

    function _mintReward(address to, uint256 amount) internal {
        if (amount == 0) return;
        _mint(to, amount);
    }

    // -------- Views --------
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
        remainingGlobal = GLOBAL_CAP > totalAll ? GLOBAL_CAP - totalAll : 0;
        remainingTerm = TERM_CAP > totalTerm ? TERM_CAP - totalTerm : 0;
        remainingPermanent = PERM_CAP > totalPermanent ? PERM_CAP - totalPermanent : 0;
    }

function collectionCount() external view returns (uint256) {
    return registeredCollections.length;
}

    function pendingRewardsView(address collection, address owner, uint256 tokenId)
        external
        view
        returns (uint256)
    {
        return s.pendingRewards(collection, owner, tokenId, numberOfBlocksPerRewardUnit);
    }

function isBluechipEnrolled(address collection, address wallet) external view returns (bool) {
    return b.bluechipWallets[collection][wallet].enrolled;
}

/// @notice Returns the total number of NFTs staked in a given collection
function collectionTotalStaked(address collection) external view returns (uint256) {
    return s.collectionTotalStaked[collection];
}

/// @notice Returns true if a collection is flagged as blue-chip
function isBluechipCollection(address collection) public view returns (bool) {
    return b.isBluechipCollection[collection]; // ✅ use your BluechipLib storage mapping
}

/// @notice Returns the tier of a collection:
/// 0 = Not Registered, 1 = Unverified (future), 2 = Verified, 3 = Blue-chip
function getCollectionTier(address collection) external view returns (uint8) {
    if (registeredIndex[collection] == 0) {
        return 0; // Not registered
    }
    if (isBluechipCollection(collection)) {
        return 3; // Blue-chip
    }
    // Currently treating all registered collections as Verified
    return 2;
}

    // ERC721 Receiver / Pause / UUPS
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private __gap;
}
