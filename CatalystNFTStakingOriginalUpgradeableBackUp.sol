// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StakingLib.sol";
import "./GovernanceLib.sol";

// OpenZeppelin (upgradeable)
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/proxy/utils/Initializable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/proxy/utils/UUPSUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/token/ERC20/ERC20Upgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/access/AccessControlUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/security/ReentrancyGuardUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/release-v4.9/contracts/security/PausableUpgradeable.sol";

// Interfaces (plain interfaces are fine)
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC721/IERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC721/IERC721Receiver.sol";

interface IOwnable { function owner() external view returns (address); }

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

    // ---------------- Roles ----------------
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // ---------------- Fee split ----------------
    uint256 public constant BURN_BP = 9000;
    uint256 public constant TREASURY_BP = 900;
    uint256 public constant DEPLOYER_BP = 100;

    // ---------------- Constants ----------------
    uint256 public constant WEIGHT_SCALE = 1e18;
    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public constant MAX_STAKE_PER_COLLECTION = 20000;

    // ---------------- Tiers ----------------
    enum CollectionTier { UNVERIFIED, VERIFIED }

    // ---------------- Storage (staking & governance libs) ----------------
    StakingLib.Storage internal s;
    GovernanceLib.Storage internal g;

    // ---------------- Parameters ----------------
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
    uint256 public tierUpgradeMinAgeBlocks;
    uint256 public tierUpgradeMinBurn;
    uint256 public tierUpgradeMinStakers;
    uint256 public tierProposalCooldownBlocks;
    uint256 public surchargeForfeitBlocks;

    // minimal registration enumeration
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

    // voting weight
    uint256 public minStakeAgeForVoting;
    uint256 public maxBaseRewardRate;

    // ---------------- Deployer & 3-of-5 Guardian Recovery ----------------
    address public deployerAddress;                 // receives the 1% deployer fee
    address[5] public backupGuardians;              // fixed slots, up to 5
    mapping(address => bool) public isGuardian;     // quick membership check

    struct RecoveryRequest {
        address proposedDeployer;
        uint8 approvals;                // count of distinct guardian approvals
        uint256 deadline;               // expiry (block timestamp)
        bool executed;
    }

    uint256 public constant RECOVERY_THRESHOLD = 3; // 3-of-5
    uint256 public constant RECOVERY_WINDOW = 3 days;
    RecoveryRequest public activeRecovery;
    mapping(address => bool) public hasApprovedActive; // guardian->approved?

    // --- Compromise detection / lock ---
    bool public recoveryLocked;

    // ---------------- Events ----------------
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payoutAmount, uint256 burnedAmount);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);

    event DeployerRecoveryProposed(address proposedDeployer, uint256 deadline);
    event DeployerRecoveryApproved(address indexed guardian, uint8 approvals);
    event DeployerRecovered(address indexed oldDeployer, address indexed newDeployer);
    event GuardianSet(uint8 indexed index, address guardian);

    event CollectionAdded(address indexed collection, uint256 declaredSupply, uint256 baseFee, uint256 surchargeEscrow, CollectionTier tier);
    event BaseRewardRateUpdated(uint256 oldValue, uint256 newValue);
    event HarvestFeeUpdated(uint256 oldValue, uint256 newValue);
    event UnstakeFeeUpdated(uint256 oldValue, uint256 newValue);
    event RegistrationFeeUpdated(uint256 oldValue, uint256 newValue);
    event VotingParamUpdated(uint8 target, uint256 oldValue, uint256 newValue);
    event ProposalExecuted(bytes32 indexed id, uint256 appliedValue);

    // compromise signals
    event CompromiseWarning(address proposedDeployer, uint256 approvals, uint256 blockNumber);
    event CompromiseConfirmed(address proposedDeployer, uint256 approvals, uint256 blockNumber);
    event RecoveryUnlocked(address indexed by, address[5] newGuardians);

    // ---------------- Init struct ----------------
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

        // optional: initial guardians
        address[5] guardians;
    }

    // ---------------- Initializer ----------------
    function initialize(InitConfig calldata cfg) public initializer {
        require(cfg.owner != address(0), "CATA: bad owner");

        __ERC20_init("Catalyst", "CATA");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _mint(cfg.owner, 25_185_000 * 10**18);

        _grantRole(DEFAULT_ADMIN_ROLE, cfg.owner);
        _grantRole(CONTRACT_ADMIN_ROLE, cfg.owner);

        // parameters
        treasuryAddress = address(this);
        deployerAddress = cfg.owner;

        numberOfBlocksPerRewardUnit = 18782; // keep your default
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

        SMALL_MIN_FEE = 1000 * 10**18;
        SMALL_MAX_FEE = 5000 * 10**18;
        MED_MIN_FEE   = 5000 * 10**18;
        MED_MAX_FEE   = 10000 * 10**18;
        LARGE_MIN_FEE = 10000 * 10**18;
        LARGE_MAX_FEE_CAP = 20000 * 10**18;

        unverifiedSurchargeBP = 20000;
        tierUpgradeMinAgeBlocks = 200000;
        tierUpgradeMinBurn = 50_000 * 10**18;
        tierUpgradeMinStakers = 50;
        tierProposalCooldownBlocks = 30000;
        surchargeForfeitBlocks = 600000;

        minStakeAgeForVoting = 100;
        maxBaseRewardRate = type(uint256).max;

        // governance (lib)
        GovernanceLib.initGov(
            g,
            cfg.votingDurationBlocks,
            cfg.minVotesRequiredScaled,
            cfg.collectionVoteCapPercent
        );

        // seed guardians
        for (uint8 i = 0; i < 5; i++) {
            _setGuardian(i, cfg.guardians[i]);
        }
    }

    // ---------------- Guardian helpers ----------------
    modifier onlyGuardian() {
        require(isGuardian[_msgSender()], "CATA: not guardian");
        _;
    }

    function _setGuardian(uint8 index, address guardian) internal {
        require(index < 5, "CATA: idx");
        address old = backupGuardians[index];
        if (old != address(0)) isGuardian[old] = false;
        backupGuardians[index] = guardian;
        if (guardian != address(0)) isGuardian[guardian] = true;
        emit GuardianSet(index, guardian);
    }

    // Admin may rotate guardians if needed (not via governance)
    function setGuardians(address[5] calldata guardians) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint8 i = 0; i < 5; i++) {
            _setGuardian(i, guardians[i]);
        }
    }

    // ---------------- Recovery lock/enable ----------------
    modifier recoveryEnabled() {
        require(!recoveryLocked, "CATA: recovery locked; reset guardians required");
        _;
    }

    // ---------------- Recovery flow (3-of-5) ----------------
    function proposeDeployerRecovery(address newDeployer)
        external
        onlyGuardian
        whenNotPaused
        recoveryEnabled
    {
        require(newDeployer != address(0), "CATA: zero");

        // reset active request
        activeRecovery.proposedDeployer = newDeployer;
        activeRecovery.approvals = 0;
        activeRecovery.deadline = block.timestamp + RECOVERY_WINDOW;
        activeRecovery.executed = false;

        // clear approvals
        for (uint8 i = 0; i < 5; i++) {
            address gaddr = backupGuardians[i];
            if (gaddr != address(0)) {
                hasApprovedActive[gaddr] = false;
            }
        }

        emit DeployerRecoveryProposed(newDeployer, activeRecovery.deadline);
    }

    function approveDeployerRecovery()
        external
        onlyGuardian
        whenNotPaused
        recoveryEnabled
    {
        require(activeRecovery.proposedDeployer != address(0), "CATA: none");
        require(!activeRecovery.executed, "CATA: executed");
        require(block.timestamp <= activeRecovery.deadline, "CATA: expired");
        require(!hasApprovedActive[_msgSender()], "CATA: voted");

        hasApprovedActive[_msgSender()] = true;
        activeRecovery.approvals += 1;

        emit DeployerRecoveryApproved(_msgSender(), activeRecovery.approvals);
    }

    function executeDeployerRecovery()
        external
        whenNotPaused
        recoveryEnabled
    {
        require(activeRecovery.proposedDeployer != address(0), "CATA: none");
        require(!activeRecovery.executed, "CATA: executed");
        require(block.timestamp <= activeRecovery.deadline, "CATA: expired");
        require(activeRecovery.approvals >= RECOVERY_THRESHOLD, "CATA: <3");

        address old = deployerAddress;
        deployerAddress = activeRecovery.proposedDeployer;
        activeRecovery.executed = true;

        // Optional: automatically remove the *old* deployer if it was a guardian
        for (uint8 i = 0; i < 5; i++) {
            if (backupGuardians[i] == old) {
                _setGuardian(i, address(0));
            }
        }

        // compromise signals & lock
        if (activeRecovery.approvals >= 5) {
            emit CompromiseConfirmed(activeRecovery.proposedDeployer, activeRecovery.approvals, block.number);
            recoveryLocked = true; // freeze further recoveries until guardians are reset
        } else if (activeRecovery.approvals == 4) {
            emit CompromiseWarning(activeRecovery.proposedDeployer, activeRecovery.approvals, block.number);
        }

        emit DeployerRecovered(old, deployerAddress);
    }

    /// @notice Unlock recovery after 5/5 lock by resetting guardians (only current deployer)
    function resetGuardians(address[5] calldata newGuardians) external {
        require(_msgSender() == deployerAddress, "CATA: only deployer");
        require(recoveryLocked, "CATA: recovery not locked");

        // wipe current guardians
        for (uint8 i = 0; i < 5; i++) {
            address oldG = backupGuardians[i];
            if (oldG != address(0)) isGuardian[oldG] = false;
            backupGuardians[i] = address(0);
        }

        // set new guardians
        for (uint8 j = 0; j < 5; j++) {
            address gaddr = newGuardians[j];
            require(gaddr != address(0), "CATA: zero guardian");
            require(!isGuardian[gaddr], "CATA: dup guardian");
            backupGuardians[j] = gaddr;
            isGuardian[gaddr] = true;
            emit GuardianSet(j, gaddr);
        }

        recoveryLocked = false;
        emit RecoveryUnlocked(_msgSender(), newGuardians);
    }

    // ---------------- Modifiers ----------------
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: cooldown");
        _;
    }

    // ---------------- Internal fee split ----------------
    function _splitFeeFromSender(address payer, uint256 amount) internal {
        require(amount > 0, "CATA: zero fee");
        uint256 burnAmt = (amount * BURN_BP) / 10000;
        uint256 treasuryAmt = (amount * TREASURY_BP) / 10000;
        uint256 deployerAmt = amount - burnAmt - treasuryAmt;

        if (burnAmt > 0) {
            _burn(payer, burnAmt);
        }
        if (deployerAmt > 0) {
            _transfer(payer, deployerAddress, deployerAmt);
        }
        if (treasuryAmt > 0) {
            _transfer(payer, address(this), treasuryAmt);
            treasuryBalance += treasuryAmt;
            emit TreasuryDeposit(payer, treasuryAmt);
        }
    }

    // ---------------- Registration ----------------
    function registerCollection(address collection, uint256 declaredMaxSupply, CollectionTier /*requestedTier*/) external nonReentrant whenNotPaused {
        require(collection != address(0), "CATA: bad addr");
        require(registeredIndex[collection] == 0, "CATA: already reg");
        require(declaredMaxSupply >= 1 && declaredMaxSupply <= MAX_STAKE_PER_COLLECTION, "CATA: supply");

        uint256 baseFee = _calculateRegistrationBaseFee(declaredMaxSupply);
        require(balanceOf(_msgSender()) >= baseFee, "CATA: insufficient");

        _splitFeeFromSender(_msgSender(), baseFee);

        StakingLib.initCollection(s, collection, declaredMaxSupply);

        registeredCollections.push(collection);
        registeredIndex[collection] = registeredCollections.length;

        emit CollectionAdded(collection, declaredMaxSupply, baseFee, 0, CollectionTier.UNVERIFIED);
    }

    // ---------------- Staking ----------------
    function termStake(address collection, uint256 tokenId) external nonReentrant notInCooldown whenNotPaused {
        require(s.collectionConfigs[collection].registered, "CATA: not reg");
        require(s.collectionConfigs[collection].totalStaked < MAX_STAKE_PER_COLLECTION, "CATA: cap");

        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakingLib.recordTermStake(
            s,
            collection,
            _msgSender(),
            tokenId,
            block.number,
            termDurationBlocks,
            rewardRateIncrementPerNFT
        );

        uint256 dynamicWelcome = welcomeBonusBaseRate + (s.totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
        if (dynamicWelcome > 0) _mint(_msgSender(), dynamicWelcome);

        lastStakingBlock[_msgSender()] = block.number;
        emit NFTStaked(_msgSender(), collection, tokenId);
    }

    function permanentStake(address collection, uint256 tokenId) external nonReentrant notInCooldown whenNotPaused {
        require(s.collectionConfigs[collection].registered, "CATA: not reg");
        require(s.collectionConfigs[collection].totalStaked < MAX_STAKE_PER_COLLECTION, "CATA: cap");

        uint256 fee = _getDynamicPermanentStakeFee();
        require(balanceOf(_msgSender()) >= fee, "CATA: insufficient");

        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        _splitFeeFromSender(_msgSender(), fee);

        StakingLib.recordPermanentStake(
            s,
            collection,
            _msgSender(),
            tokenId,
            block.number,
            rewardRateIncrementPerNFT
        );

        uint256 dynamicWelcome = welcomeBonusBaseRate + (s.totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
        if (dynamicWelcome > 0) _mint(_msgSender(), dynamicWelcome);

        lastStakingBlock[_msgSender()] = block.number;
        emit NFTStaked(_msgSender(), collection, tokenId);
    }

    function unstake(address collection, uint256 tokenId) public nonReentrant whenNotPaused {
        StakingLib.StakeInfo memory info = s.stakeLog[collection][_msgSender()][tokenId];
        require(info.currentlyStaked, "CATA: not staked");
        if (!info.isPermanent) require(block.number >= info.unstakeDeadlineBlock, "CATA: term active");

        // harvest
        uint256 reward = StakingLib.pendingRewards(s, collection, _msgSender(), tokenId, numberOfBlocksPerRewardUnit);
        if (reward > 0) {
            uint256 feeRate = _getDynamicHarvestBurnFeeRate();
            uint256 burnAmt = (reward * feeRate) / 100;
            _mint(_msgSender(), reward);
            if (burnAmt > 0) {
                _burn(_msgSender(), burnAmt);
                burnedCatalystByAddress[_msgSender()] += burnAmt;
                lastBurnBlock[_msgSender()] = block.number;
                if (!isParticipating[_msgSender()]) { isParticipating[_msgSender()] = true; participatingWallets.push(_msgSender()); }
            }
            StakingLib.updateLastHarvest(s, collection, _msgSender(), tokenId);
            emit RewardsHarvested(_msgSender(), collection, reward - burnAmt, burnAmt);
        }

        require(balanceOf(_msgSender()) >= unstakeBurnFee, "CATA: fee");
        _splitFeeFromSender(_msgSender(), unstakeBurnFee);

        StakingLib.recordUnstake(s, collection, _msgSender(), tokenId, rewardRateIncrementPerNFT);

        IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);

        emit NFTUnstaked(_msgSender(), collection, tokenId);
    }

    // ---------------- Batch ----------------
    function batchTermStake(address collection, uint256[] calldata tokenIds) external {
        require(tokenIds.length > 0 && tokenIds.length <= MAX_HARVEST_BATCH, "CATA: batch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            this.termStake(collection, tokenIds[i]);
        }
    }

    function batchPermanentStake(address collection, uint256[] calldata tokenIds) external {
        require(tokenIds.length > 0 && tokenIds.length <= MAX_HARVEST_BATCH, "CATA: batch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            this.permanentStake(collection, tokenIds[i]);
        }
    }

    function batchUnstake(address collection, uint256[] calldata tokenIds) external {
        require(tokenIds.length > 0 && tokenIds.length <= MAX_HARVEST_BATCH, "CATA: batch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            this.unstake(collection, tokenIds[i]);
        }
    }

    // ---------------- Harvest only ----------------
    function harvest(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        uint256 reward = StakingLib.pendingRewards(s, collection, _msgSender(), tokenId, numberOfBlocksPerRewardUnit);
        if (reward == 0) return;
        uint256 feeRate = _getDynamicHarvestBurnFeeRate();
        uint256 burnAmt = (reward * feeRate) / 100;
        _mint(_msgSender(), reward);
        if (burnAmt > 0) {
            _burn(_msgSender(), burnAmt);
            burnedCatalystByAddress[_msgSender()] += burnAmt;
            lastBurnBlock[_msgSender()] = block.number;
            if (!isParticipating[_msgSender()]) { isParticipating[_msgSender()] = true; participatingWallets.push(_msgSender()); }
        }
        StakingLib.updateLastHarvest(s, collection, _msgSender(), tokenId);
        emit RewardsHarvested(_msgSender(), collection, reward - burnAmt, burnAmt);
    }

    // ---------------- Governance wrappers (same API) ----------------
    function propose(
        GovernanceLib.ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collectionContext
    ) external whenNotPaused returns (bytes32) {
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
        require(weight > 0, "CATA: not eligible");
        GovernanceLib.castVote(g, id, _msgSender(), weight, attributedCollection);
    }

    function executeProposal(bytes32 id) external whenNotPaused nonReentrant {
        GovernanceLib.Proposal memory p = GovernanceLib.validateForExecution(g, id);
        GovernanceLib.markExecuted(g, id);

        if (p.pType == GovernanceLib.ProposalType.BASE_REWARD) {
            uint256 old = s.baseRewardRate;
            s.baseRewardRate = p.newValue > maxBaseRewardRate ? maxBaseRewardRate : p.newValue;
            emit BaseRewardRateUpdated(old, s.baseRewardRate);
            emit ProposalExecuted(id, s.baseRewardRate);
        } else if (p.pType == GovernanceLib.ProposalType.HARVEST_FEE) {
            require(p.newValue <= 100, "CATA: fee>100");
            uint256 oldHF = initialHarvestBurnFeeRate;
            initialHarvestBurnFeeRate = p.newValue;
            emit HarvestFeeUpdated(oldHF, p.newValue);
            emit ProposalExecuted(id, p.newValue);
        } else if (p.pType == GovernanceLib.ProposalType.UNSTAKE_FEE) {
            uint256 oldUF = unstakeBurnFee;
            unstakeBurnFee = p.newValue;
            emit UnstakeFeeUpdated(oldUF, p.newValue);
            emit ProposalExecuted(id, p.newValue);
        } else if (p.pType == GovernanceLib.ProposalType.REGISTRATION_FEE_FALLBACK) {
            uint256 oldRF = collectionRegistrationFee;
            collectionRegistrationFee = p.newValue;
            emit RegistrationFeeUpdated(oldRF, p.newValue);
            emit ProposalExecuted(id, p.newValue);
        } else if (p.pType == GovernanceLib.ProposalType.VOTING_PARAM) {
            uint8 t = p.paramTarget;
            if (t == 0) {
                uint256 old = g.minVotesRequiredScaled;
                g.minVotesRequiredScaled = p.newValue;
                emit VotingParamUpdated(t, old, p.newValue);
            } else if (t == 1) {
                uint256 old = g.votingDurationBlocks;
                g.votingDurationBlocks = p.newValue;
                emit VotingParamUpdated(t, old, p.newValue);
            } else if (t == 2) {
                require(p.newValue <= WEIGHT_SCALE, "CATA: >1");
                uint256 old = g.collectionVoteCapPercent;
                g.collectionVoteCapPercent = p.newValue;
                emit VotingParamUpdated(t, old, p.newValue);
            } else {
                revert("CATA: unknown target");
            }
            emit ProposalExecuted(id, p.newValue);
        } else {
            revert("CATA: proposal type not handled here");
        }
    }

    // ---------------- Voting weight ----------------
    function _votingWeight(address voter) internal view returns (uint256 weight, address attributedCollection) {
        for (uint256 i = 0; i < registeredCollections.length; i++) {
            address coll = registeredCollections[i];
            uint256[] storage port = s.stakePortfolioByUser[coll][voter];
            if (port.length == 0) continue;
            for (uint256 j = 0; j < port.length; j++) {
                StakingLib.StakeInfo storage si = s.stakeLog[coll][voter][port[j]];
                if (si.currentlyStaked && block.number >= si.stakeBlock + minStakeAgeForVoting) {
                    return (WEIGHT_SCALE, coll);
                }
            }
        }
        return (0, address(0));
    }

    // ---------------- Math & views ----------------
    function _sqrt(uint256 y) internal pure returns (uint256 z) { return StakingLib.sqrt(y); }

    function _getDynamicPermanentStakeFee() public view returns (uint256) {
        return initialCollectionFee + (_sqrt(s.totalStakedNFTsCount) * feeMultiplier);
    }

    function _getDynamicHarvestBurnFeeRate() public view returns (uint256) {
        if (harvestRateAdjustmentFactor == 0) return initialHarvestBurnFeeRate;
        uint256 userBurn = burnedCatalystByAddress[_msgSender()];
        uint256 adjust = userBurn / harvestRateAdjustmentFactor;
        if (adjust >= initialHarvestBurnFeeRate) return 0;
        return initialHarvestBurnFeeRate - adjust;
    }

    function _calculateRegistrationBaseFee(uint256 declaredSupply) internal view returns (uint256) {
        if (declaredSupply <= 1000) return SMALL_MIN_FEE;
        if (declaredSupply <= 5000) return SMALL_MAX_FEE;
        if (declaredSupply <= 10000) return MED_MAX_FEE;
        uint256 fee = LARGE_MIN_FEE + ((declaredSupply - 10000) * feeMultiplier) / 1000;
        if (fee > LARGE_MAX_FEE_CAP) fee = LARGE_MAX_FEE_CAP;
        return fee;
    }

    // ---------------- Treasury ----------------
    function withdrawTreasury(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(to != address(0), "CATA: bad addr");
        require(amount <= treasuryBalance, "CATA: balance");
        treasuryBalance -= amount;
        _transfer(address(this), to, amount);
        emit TreasuryWithdrawal(to, amount);
    }

    // ---------------- ERC721 Receiver ----------------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ---------------- Pause ----------------
    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }

    // ---------------- UUPS authorization ----------------
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ---------------- Storage gap ----------------
    uint256[45] private __gap;
}
