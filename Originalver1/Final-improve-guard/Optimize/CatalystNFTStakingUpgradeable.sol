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
    error ThresholdNotMet();
    error Insufficient();
    error AlreadyEnrolled();
    error DuplicateGuardian();
    error NotAnOwner();
    error NoToken();
    error NotAGuardian();
    error ExistingGuardian();
    error NotBluechip();
    error StakingCapReached();
    error AlreadyStaked();
    error NotEnrolled();
    error NotStakedForCollection();
    error ZeroWeight();
    error NotFound();
    error ProposalClosed();
    error AlreadyVoted();
    error QuorumNotMet();
    error VotingStillOpen();
    error AlreadyExecuted();
    error NotAnAdmin();

    // -------- Roles --------
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");
    bytes32 public constant GUARDIAN_COUNCIL_ROLE = keccak256("GUARDIAN_COUNCIL_ROLE");

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
    GuardianLib.Storage internal d; // Using 'd' for consistency with previous optimization

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
    mapping(address => uint256) public burnedCatalystByAddress;
    mapping(address => uint256) public lastStakingBlock;

    // -------- Events --------
    event CollectionTierUpgraded(address indexed collection, StakingLib.Tier newTier);
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
    event DeployerRecovered(address indexed oldDeployer, address indexed newDeployer);
    event AdminRecovered(address indexed newAdmin);
    event GuardianSet(bytes32 indexed councilId, uint8 indexed idx, address guardian);
    event RecoveryProposed(bytes32 indexed councilId, address indexed proposer, address proposed, uint256 deadline);
    event RecoveryApproved(bytes32 indexed councilId, address indexed guardian, uint8 approvals);
    event Recovered(bytes32 indexed councilId, address oldAddress, address newAddress);

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

        g.initGov(
            cfg.votingDurationBlocks,
            cfg.minVotesRequiredScaled,
            cfg.collectionVoteCapPercent
        );
        
        d.init(
            cfg.deployerGuardians,
            cfg.deployerThreshold,
            cfg.adminGuardians,
            cfg.adminThreshold
        );

        b.bluechipWalletFee = cfg.bluechipWalletFee;
        _mint(cfg.owner, 100_000_000 * 1e18);
    }
    
    // -------- Modifiers --------
    modifier onlyAdmin() {
        if (_msgSender() != deployerAddress && !hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) revert Unauthorized();
        _;
    }

    modifier onlyRegistered(address collection) {
        if (!s.collectionConfigs[collection].registered) revert NotRegistered();
        _;
    }

    modifier onlyContractAdmin() {
        if (!hasRole(CONTRACT_ADMIN_ROLE, _msgSender())) revert Unauthorized();
        _;
    }

    modifier onlyDeployerGuardian() {
        if (!d.isGuardian(GuardianLib.DEPLOYER_COUNCIL_ID, _msgSender())) revert Unauthorized();
        _;
    }

    modifier onlyAdminGuardian() {
        if (!d.isGuardian(GuardianLib.ADMIN_COUNCIL_ID, _msgSender())) revert Unauthorized();
        _;
    }

    modifier notInCooldown() {
        if (block.number < lastStakingBlock[_msgSender()] + stakingCooldownBlocks) revert Cooldown();
        _;
    }

    // -------- Guardians: admin setters --------
    function setDeployerGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        d.setGuardian(GuardianLib.DEPLOYER_COUNCIL_ID, idx, guardian);
    }

    function setAdminGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        d.setGuardian(GuardianLib.ADMIN_COUNCIL_ID, idx, guardian);
    }

    // -------- Deployer recovery --------
    function proposeDeployerRecovery(address newDeployer) external whenNotPaused onlyDeployerGuardian {
        d.proposeRecovery(GuardianLib.DEPLOYER_COUNCIL_ID, newDeployer, RECOVERY_WINDOW, _msgSender());
    }

    function approveDeployerRecovery() external whenNotPaused onlyDeployerGuardian {
        d.approveRecovery(GuardianLib.DEPLOYER_COUNCIL_ID, _msgSender());
    }

    function executeDeployerRecovery() external whenNotPaused {
        address old = deployerAddress;
        address newDeployer = d.executeRecovery(GuardianLib.DEPLOYER_COUNCIL_ID);
        deployerAddress = newDeployer;
        emit DeployerRecovered(old, newDeployer);
    }

    // -------- Admin recovery --------
    function proposeAdminRecovery(address newAdmin) external whenNotPaused onlyAdminGuardian {
        d.proposeRecovery(GuardianLib.ADMIN_COUNCIL_ID, newAdmin, RECOVERY_WINDOW, _msgSender());
    }

    function approveAdminRecovery() external whenNotPaused onlyAdminGuardian {
        d.approveRecovery(GuardianLib.ADMIN_COUNCIL_ID, _msgSender());
    }

    function executeAdminRecovery() external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        address newAdmin = d.executeRecovery(GuardianLib.ADMIN_COUNCIL_ID);
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        emit AdminRecovered(newAdmin);
    }

    // -------- Registration (permissionless with fee guard) --------
    function registerCollection(address collection, uint256 declaredMaxSupply) external whenNotPaused nonReentrant {
        if (collection == address(0)) revert ZeroAddress();
        if (s.collectionConfigs[collection].registered) revert AlreadyExists();
        if (declaredMaxSupply == 0 || declaredMaxSupply > MAX_STAKE_PER_COLLECTION) revert BadParam();

        uint256 fee = collectionRegistrationFee;
        if (fee > 0) _splitFeeFromSender(_msgSender(), fee);

        s.initCollection(collection, declaredMaxSupply);
        registeredCollections.push(collection);
        
        emit CollectionAdded(collection, declaredMaxSupply, fee);
    }

    function isCollectionRegistered(address collection) external view returns (bool) {
        return s.collectionConfigs[collection].registered;
    }

    // -------- Custodial Staking --------
    function stake(address collection, uint256 tokenId, bool permanent)
        public
        whenNotPaused
        nonReentrant
        notInCooldown
    {
        if (collection == address(0)) revert ZeroAddress();
        if (!s.collectionConfigs[collection].registered) revert NotRegistered();
        if (s.stakeLog[collection][_msgSender()][tokenId].currentlyStaked) revert AlreadyStaked();
        
        // transfer NFT (requires approval)
        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        if (permanent) {
            s.recordPermanentStake(
                collection,
                _msgSender(),
                tokenId,
                block.number
            );
        } else {
            s.recordTermStake(
                collection,
                _msgSender(),
                tokenId,
                block.number,
                termDurationBlocks
            );
        }

        lastStakingBlock[_msgSender()] = block.number;
        emit NFTStaked(_msgSender(), collection, tokenId, permanent);
    }

    function batchStake(address collection, uint256[] calldata tokenIds, bool permanent) external whenNotPaused nonReentrant {
        uint256 n = tokenIds.length;
        if (n == 0 || n > MAX_HARVEST_BATCH) revert BatchTooLarge();
        for (uint256 i = 0; i < n; ++i) {
            stake(collection, tokenIds[i], permanent);
        }
    }

    function _pendingRewardInternal(address collection, address owner, uint256 tokenId) internal view returns (uint256) {
        return s.pendingRewards(collection, owner, tokenId, numberOfBlocksPerRewardUnit);
    }

    function harvest(address collection, uint256 tokenId) public whenNotPaused nonReentrant {
        StakingLib.StakeInfo storage si = s.stakeLog[collection][_msgSender()][tokenId];
        if (!si.currentlyStaked) revert NotStaked();

        uint256 reward = _pendingRewardInternal(collection, _msgSender(), tokenId);
        if (reward == 0) return;

        uint256 harvestBurnFee = initialHarvestBurnFeeRate;
        uint256 burnAmt = (reward * harvestBurnFee) / BP_DENOM;
        uint256 mintAmount = reward - burnAmt;

        _mint(_msgSender(), mintAmount);
        if (burnAmt > 0) {
            _burn(_msgSender(), burnAmt);
            burnedCatalystByAddress[_msgSender()] += burnAmt;
        }
        s.updateLastHarvest(collection, _msgSender(), tokenId);
        emit RewardsHarvested(_msgSender(), collection, mintAmount, burnAmt);
    }
    
    function harvestBatch(address collection, uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        uint256 n = tokenIds.length;
        if (n == 0 || n > 200) revert BadParam(); // safety cap for front-end
        for (uint256 i = 0; i < n; ++i) {
            harvest(collection, tokenIds[i]);
        }
    }

    function unstake(address collection, uint256 tokenId) public whenNotPaused nonReentrant {
        StakingLib.StakeInfo memory info = s.stakeLog[collection][_msgSender()][tokenId];
        if (!info.currentlyStaked) revert NotStaked();
        if (!info.isPermanent && block.number < info.unstakeDeadlineBlock) revert TermNotExpired();

        // harvest pending
        uint256 reward = _pendingRewardInternal(collection, _msgSender(), tokenId);
        if (reward > 0) {
            uint256 harvestBurnFee = initialHarvestBurnFeeRate;
            uint256 burnAmt = (reward * harvestBurnFee) / BP_DENOM;
            uint256 mintAmount = reward - burnAmt;
            _mint(_msgSender(), mintAmount);
            if (burnAmt > 0) {
                _burn(_msgSender(), burnAmt);
                burnedCatalystByAddress[_msgSender()] += burnAmt;
            }
            s.updateLastHarvest(collection, _msgSender(), tokenId);
            emit RewardsHarvested(_msgSender(), collection, mintAmount, burnAmt);
        }

        if (unstakeBurnFee > 0) {
            if (balanceOf(_msgSender()) < unstakeBurnFee) revert Insufficient();
            _burn(_msgSender(), unstakeBurnFee);
            burnedCatalystByAddress[_msgSender()] += unstakeBurnFee;
        }

        s.recordUnstake(collection, _msgSender(), tokenId);

        // transfer NFT back
        IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);
        emit NFTUnstaked(_msgSender(), collection, tokenId);
    }

    function unstakeBatch(address collection, uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        uint256 n = tokenIds.length;
        if (n == 0 || n > 200) revert BadParam();
        for (uint256 i = 0; i < n; ++i) {
            unstake(collection, tokenIds[i]);
        }
    }


    // -------- Blue-chip (non-custodial) --------
    function setBluechipCollection(address collection, bool isBluechip)
        external
        onlyRole(CONTRACT_ADMIN_ROLE)
        whenNotPaused
        onlyRegistered(collection)
    {
        b.isBluechipCollection[collection] = isBluechip;
        emit BluechipCollectionSet(collection, isBluechip);
    }

    function enrollBluechip() external whenNotPaused nonReentrant {
        address wallet = _msgSender();
        if (b.bluechipWallets[address(0)][wallet].enrolled) revert AlreadyEnrolled();
        uint256 fee = b.bluechipWalletFee;
        b.enroll(b, address(0), wallet, block.number, fee, _splitFeeFromSender);
    }

    function harvestBluechip(address collection) external whenNotPaused nonReentrant {
        if (!b.isBluechipCollection[collection]) revert NotBluechip();
        if (IERC721(collection).balanceOf(_msgSender()) == 0) revert NoToken();
        b.harvest(b, collection, _msgSender(), block.number, s.baseRewardRate, numberOfBlocksPerRewardUnit, _mintReward);
    }

    // -------- Governance wrappers --------
    function propose(
        GovernanceLib.ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collectionContext
    ) external whenNotPaused returns (bytes32) {
        (uint256 weight, address attributedCollection) = _votingWeight(_msgSender());
        if (weight == 0) revert Ineligible();

        return g.createProposal(
            g,
            pType,
            paramTarget,
            newValue,
            collectionContext,
            _msgSender()
        );
    }

    function vote(bytes32 id) external whenNotPaused {
        (uint256 weight, address attributedCollection) = _votingWeight(_msgSender());
        if (weight == 0) revert Ineligible();
        g.castVote(g, id, _msgSender(), weight, attributedCollection);
    }

    function executeProposal(bytes32 id) external whenNotPaused nonReentrant {
        GovernanceLib.Proposal memory p = g.validateForExecution(g, id);
        g.markExecuted(g, id);

        if (p.pType == GovernanceLib.ProposalType.BASE_REWARD) {
            uint256 old = s.baseRewardRate;
            s.baseRewardRate = p.newValue > maxBaseRewardRate ? maxBaseRewardRate : p.newValue;
            emit BaseRewardRateUpdated(old, s.baseRewardRate);
        } else if (p.pType == GovernanceLib.ProposalType.HARVEST_FEE) {
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
            else if (t == 2) { uint256 old = g.collectionVoteCapPercent; g.collectionVoteCapPercent = p.newValue; emit VotingParamUpdated(t, old, p.newValue); }
            else revert BadParam();
        } else if (p.pType == GovernanceLib.ProposalType.TIER_UPGRADE) {
            StakingLib.CollectionConfig storage cfg = s.collectionConfigs[p.collectionAddress];
            if (!cfg.registered) revert NotRegistered();
            cfg.tier = StakingLib.Tier.BLUECHIP;
            b.isBluechipCollection[p.collectionAddress] = true;
            emit CollectionTierUpgraded(p.collectionAddress, StakingLib.Tier.BLUECHIP);
        } else {
            revert BadParam();
        }

        emit ProposalExecuted(id, p.newValue);
    }

    function _votingWeight(address voter) internal view returns (uint256 weight, address attributedCollection) {
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
        totalAll = s.totalStakedNFTsCount;
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

    function collectionTotalStaked(address collection) external view returns (uint256) {
        return s.collectionTotalStaked[collection];
    }

    function isBluechipCollection(address collection) public view returns (bool) {
        return b.isBluechipCollection[collection];
    }

    function getCollectionTier(address collection) external view returns (uint8) {
        if (!s.collectionConfigs[collection].registered) {
            return 0; // Not registered
        }
        if (isBluechipCollection(collection)) {
            return 3; // Blue-chip
        }
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
