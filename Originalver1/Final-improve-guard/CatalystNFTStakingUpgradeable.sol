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
    GuardianLib.Storage internal gu;

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

    // -------- Events --------
    event DeployerRecovered(address indexed oldDeployer, address indexed newDeployer);
    event AdminRecovered(address indexed newAdmin);
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
        
        GuardianLib.init(
            gu,
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
        if (!gu.isGuardian(gu, GuardianLib.DEPLOYER_COUNCIL_ID, _msgSender())) revert Unauthorized();
        _;
    }

    modifier onlyAdminGuardian() {
        if (!gu.isGuardian(gu, GuardianLib.ADMIN_COUNCIL_ID, _msgSender())) revert Unauthorized();
        _;
    }

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
        gu.approveRecovery(gu, GuardianLib.DEPLOYER_COUNCIL_ID, _msgSender());
    }
    function executeDeployerRecovery() external whenNotPaused {
        if (gu.executeRecovery(gu, GuardianLib.DEPLOYER_COUNCIL_ID) != address(0)) {
            address newDeployer = gu.executeRecovery(gu, GuardianLib.DEPLOYER_COUNCIL_ID);
            deployerAddress = newDeployer;
            emit DeployerRecovered(address(0), newDeployer);
        }
    }

    // -------- Admin recovery --------
    function proposeAdminRecovery(address newAdmin) external whenNotPaused onlyAdminGuardian {
        gu.proposeRecovery(gu, GuardianLib.ADMIN_COUNCIL_ID, newAdmin, RECOVERY_WINDOW, _msgSender());
    }
    function approveAdminRecovery() external whenNotPaused onlyAdminGuardian {
        gu.approveRecovery(gu, GuardianLib.ADMIN_COUNCIL_ID, _msgSender());
    }
    function executeAdminRecovery() external whenNotPaused {
        if (gu.executeRecovery(gu, GuardianLib.ADMIN_COUNCIL_ID) != address(0)) {
            address newAdmin = gu.executeRecovery(gu, GuardianLib.ADMIN_COUNCIL_ID);
            _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
            emit AdminRecovered(newAdmin);
        }
    }

    // -------- Staking logic --------
    function registerCollection(address collection, uint256 declaredSupply) external whenNotPaused {
        if (s.collectionConfigs[collection].registered) revert AlreadyExists();
        if (declaredSupply == 0) revert BadParam();

        _mint(_msgSender(), collectionRegistrationFee);
        _burn(_msgSender(), collectionRegistrationFee);
        
        s.collectionConfigs[collection].registered = true;
        s.collectionConfigs[collection].declaredSupply = declaredSupply;
        registeredCollections.push(collection);
        registeredIndex[collection] = registeredCollections.length - 1;

        emit CollectionAdded(collection, declaredSupply, collectionRegistrationFee);
    }

    function stake(address collection, uint256 tokenId, bool permanent) external whenNotPaused nonReentrant {
        if (!s.collectionConfigs[collection].registered) revert NotRegistered();
        
        StakingLib.StakeInfo memory info = s.stakeLog[collection][_msgSender()][tokenId];
        if (info.currentlyStaked) revert AlreadyExists();

        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);
        
        s.stake(
            collection,
            _msgSender(),
            tokenId,
            permanent,
            termDurationBlocks,
            stakingCooldownBlocks,
            block.number
        );
        
        s.updateBaseRewardRate(rewardRateIncrementPerNFT, maxBaseRewardRate);
        
        emit NFTStaked(_msgSender(), collection, tokenId, permanent);
    }

    function batchStake(
        address collection,
        uint256[] memory tokenIds,
        bool permanent
    ) external {
        if (tokenIds.length > MAX_HARVEST_BATCH) revert BatchTooLarge();
        
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            stake(collection, tokenIds[i], permanent);
        }
    }

    function unstake(address collection, uint256 tokenId) external whenNotPaused nonReentrant {
        if (!s.stakeLog[collection][_msgSender()][tokenId].currentlyStaked) revert NotStaked();
        
        if (!s.stakeLog[collection][_msgSender()][tokenId].isPermanent && block.number < s.stakeLog[collection][_msgSender()][tokenId].unstakeDeadlineBlock) {
            revert TermNotExpired();
        }
        
        if (block.number < lastStakingBlock[_msgSender()] + stakingCooldownBlocks) {
            revert Cooldown();
        }

        s.unstake(collection, _msgSender(), tokenId);
        s.updateBaseRewardRate(rewardRateIncrementPerNFT, maxBaseRewardRate);
        _burn(_msgSender(), unstakeBurnFee);

        IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);
        
        lastStakingBlock[_msgSender()] = block.number;
        
        emit NFTUnstaked(_msgSender(), collection, tokenId);
    }

    function batchUnstake(
        address collection,
        uint256[] memory tokenIds
    ) external {
        if (tokenIds.length > MAX_HARVEST_BATCH) revert BatchTooLarge();
        
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            unstake(collection, tokenIds[i]);
        }
    }

    function harvest(address collection, uint256 tokenId) external whenNotPaused nonReentrant {
        (uint256 grossReward, uint256 burnedAmount) = calculateRewards(collection, _msgSender(), tokenId);

        if (grossReward == 0) revert Insufficient();

        _mint(_msgSender(), grossReward - burnedAmount);
        _burn(_msgSender(), burnedAmount);

        s.updateLastHarvest(collection, _msgSender(), tokenId, block.number);
        
        emit RewardsHarvested(_msgSender(), collection, grossReward, burnedAmount);
    }

    function batchHarvest(address collection, uint256[] memory tokenIds) external {
        if (tokenIds.length > MAX_HARVEST_BATCH) revert BatchTooLarge();

        for (uint256 i = 0; i < tokenIds.length; ++i) {
            harvest(collection, tokenIds[i]);
        }
    }

    function harvestAll() external whenNotPaused nonReentrant {
        address[] memory userCollections = s.getUserStakedCollections(_msgSender());
        uint256 totalGrossReward = 0;
        uint256 totalBurnedAmount = 0;
        
        for (uint256 i = 0; i < userCollections.length; ++i) {
            address collection = userCollections[i];
            uint256[] memory userTokens = s.getUserStakedTokens(collection, _msgSender());
            for (uint256 j = 0; j < userTokens.length; ++j) {
                (uint256 grossReward, uint256 burnedAmount) = calculateRewards(collection, _msgSender(), userTokens[j]);
                if (grossReward > 0) {
                    _mint(_msgSender(), grossReward - burnedAmount);
                    _burn(_msgSender(), burnedAmount);
                    s.updateLastHarvest(collection, _msgSender(), userTokens[j], block.number);
                    emit RewardsHarvested(_msgSender(), collection, grossReward, burnedAmount);
                    totalGrossReward += grossReward;
                    totalBurnedAmount += burnedAmount;
                }
            }
        }
    }
    
    function calculateRewards(address collection, address owner, uint256 tokenId) public view returns (uint256 grossReward, uint256 burnedAmount) {
        uint256 baseReward = s.pendingRewards(collection, owner, tokenId, numberOfBlocksPerRewardUnit);
        uint256 harvestFee = (baseReward * initialHarvestBurnFeeRate) / 10000;
        
        return (baseReward, harvestFee);
    }

    function setBaseRewardRate(uint256 rate) external onlyContractAdmin {
        uint256 oldRate = s.baseRewardRate;
        s.baseRewardRate = rate;
        emit BaseRewardRateUpdated(oldRate, rate);
    }

    function setHarvestFee(uint256 fee) external onlyContractAdmin {
        uint256 oldFee = initialHarvestBurnFeeRate;
        initialHarvestBurnFeeRate = fee;
        emit HarvestFeeUpdated(oldFee, fee);
    }

    function setUnstakeFee(uint256 fee) external onlyContractAdmin {
        uint256 oldFee = unstakeBurnFee;
        unstakeBurnFee = fee;
        emit UnstakeFeeUpdated(oldFee, fee);
    }

    function setRegistrationFee(uint256 fee) external onlyContractAdmin {
        uint256 oldFee = collectionRegistrationFee;
        collectionRegistrationFee = fee;
        emit RegistrationFeeUpdated(oldFee, fee);
    }

    function proposeSetBaseRewardRate(uint256 newRate) external onlyAdmin {
        bytes32 propId = g.createProposal(
            GovernanceLib.ProposalType.BASE_REWARD,
            0,
            newRate,
            address(0),
            _msgSender(),
            block.number,
            g.votingDurationBlocks
        );
        s.proposals[propId] = g.proposals[propId];
    }
    
    function proposeSetHarvestFee(uint256 newFee) external onlyAdmin {
        bytes32 propId = g.createProposal(
            GovernanceLib.ProposalType.HARVEST_FEE,
            0,
            newFee,
            address(0),
            _msgSender(),
            block.number,
            g.votingDurationBlocks
        );
        s.proposals[propId] = g.proposals[propId];
    }
    
    function proposeSetUnstakeFee(uint256 newFee) external onlyAdmin {
        bytes32 propId = g.createProposal(
            GovernanceLib.ProposalType.UNSTAKE_FEE,
            0,
            newFee,
            address(0),
            _msgSender(),
            block.number,
            g.votingDurationBlocks
        );
        s.proposals[propId] = g.proposals[propId];
    }
    
    function proposeSetRegistrationFee(uint256 newFee) external onlyAdmin {
        bytes32 propId = g.createProposal(
            GovernanceLib.ProposalType.REGISTRATION_FEE_FALLBACK,
            0,
            newFee,
            address(0),
            _msgSender(),
            block.number,
            g.votingDurationBlocks
        );
        s.proposals[propId] = g.proposals[propId];
    }

    function vote(bytes32 proposalId) external {
        (address collection, uint256 tokenId, bool currentlyStaked) = s.stakeLog[collection][_msgSender()][0];
        if (!currentlyStaked) revert Ineligible();
        
        address attributedCollection = collection;
        uint256 weightScaled = 1;

        g.vote(
            proposalId,
            _msgSender(),
            weightScaled,
            attributedCollection
        );
    }

    function executeProposal(bytes32 proposalId) external {
        GovernanceLib.Proposal memory p = g.validateForExecution(proposalId);
        
        if (p.pType == GovernanceLib.ProposalType.BASE_REWARD) {
            setBaseRewardRate(p.newValue);
        } else if (p.pType == GovernanceLib.ProposalType.HARVEST_FEE) {
            setHarvestFee(p.newValue);
        } else if (p.pType == GovernanceLib.ProposalType.UNSTAKE_FEE) {
            setUnstakeFee(p.newValue);
        } else if (p.pType == GovernanceLib.ProposalType.REGISTRATION_FEE_FALLBACK) {
            setRegistrationFee(p.newValue);
        } else {
            revert BadParam();
        }
        
        g.markExecuted(proposalId);
        emit ProposalExecuted(proposalId, p.newValue);
    }

    // -------- Staking getters --------
    function getTotalStaked() external view returns (uint256) {
        return s.totalStakedAll;
    }

    function getTotalStakedTerm() external view returns (uint256) {
        return s.totalStakedTerm;
    }
    
    function getTotalStakedPermanent() external view returns (uint256) {
        return s.totalStakedPermanent;
    }

    function getStakedStatus(address collection, address owner, uint256 tokenId) external view returns (bool) {
        return s.stakeLog[collection][owner][tokenId].currentlyStaked;
    }

    function getStakedInfo(address collection, address owner, uint256 tokenId) external view returns (StakingLib.StakeInfo memory) {
        return s.stakeLog[collection][owner][tokenId];
    }

    function getStakedTokens(address collection, address owner) external view returns (uint256[] memory) {
        return s.getUserStakedTokens(collection, owner);
    }

    function getStakedCollections(address owner) external view returns (address[] memory) {
        return s.getUserStakedCollections(owner);
    }

    function getCollectionConfig(address collection) external view returns (StakingLib.CollectionConfig memory) {
        return s.collectionConfigs[collection];
    }

    function getCollectionCount() external view returns (uint256) {
        return registeredCollections.length;
    }

    function getRegisteredCollections() external view returns (address[] memory) {
        return registeredCollections;
    }
    
    function getCollectionIndex(address collection) external view returns (uint256) {
        return registeredIndex[collection];
    }
    
    function getBluechipEnrollment(address collection, address wallet) external view returns (bool) {
        return b.bluechipWallets[collection][wallet].enrolled;
    }

    function collectionTotalStaked(address collection) external view returns (uint256) {
        return s.collectionTotalStaked[collection];
    }

    function isBluechipCollection(address collection) public view returns (bool) {
        return b.isBluechipCollection[collection];
    }

    function getCollectionTier(address collection) external view returns (uint8) {
        if (registeredIndex[collection] == 0) {
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
}
