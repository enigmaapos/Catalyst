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
    error NotTheOwner();
    error NoToken();

    // -------- Roles --------
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");
    bytes32 public constant STAKING_ADMIN_ROLE = keccak256("STAKING_ADMIN_ROLE");
    bytes32 public constant GOVERNANCE_ADMIN_ROLE = keccak256("GOVERNANCE_ADMIN_ROLE");
    bytes32 public constant BLUECHIP_ADMIN_ROLE = keccak256("BLUECHIP_ADMIN_ROLE");

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
        if (!gu.isGuardian(GuardianLib.DEPLOYER_COUNCIL_ID, _msgSender())) revert Unauthorized();
        _;
    }

    modifier onlyAdminGuardian() {
        if (!gu.isGuardian(GuardianLib.ADMIN_COUNCIL_ID, _msgSender())) revert Unauthorized();
        _;
    }

    // -------- Guardians: admin setters --------
    function setDeployerGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gu.setGuardian(GuardianLib.DEPLOYER_COUNCIL_ID, idx, guardian);
    }

    function setAdminGuardian(uint8 idx, address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gu.setGuardian(GuardianLib.ADMIN_COUNCIL_ID, idx, guardian);
    }

    // -------- Deployer recovery --------
    function proposeDeployerRecovery(address newDeployer) external whenNotPaused onlyDeployerGuardian {
        gu.proposeRecovery(GuardianLib.DEPLOYER_COUNCIL_ID, newDeployer, RECOVERY_WINDOW, _msgSender());
    }

    function approveDeployerRecovery() external whenNotPaused onlyDeployerGuardian {
        if (gu.approveRecovery(GuardianLib.DEPLOYER_COUNCIL_ID, _msgSender()) < gu.deployerCouncil.threshold) {
            revert Threshold();
        }
    }

    function executeDeployerRecovery() external whenNotPaused {
        address old = deployerAddress;
        address newDeployer = gu.executeRecovery(GuardianLib.DEPLOYER_COUNCIL_ID);
        deployerAddress = newDeployer;
        emit DeployerRecovered(old, newDeployer);
    }

    // -------- Admin recovery --------
    function proposeAdminRecovery(address newAdmin) external whenNotPaused onlyAdminGuardian {
        gu.proposeRecovery(GuardianLib.ADMIN_COUNCIL_ID, newAdmin, RECOVERY_WINDOW, _msgSender());
    }

    function approveAdminRecovery() external whenNotPaused onlyAdminGuardian {
        if (gu.approveRecovery(GuardianLib.ADMIN_COUNCIL_ID, _msgSender()) < gu.adminCouncil.threshold) {
            revert Threshold();
        }
    }

    function executeAdminRecovery() external whenNotPaused {
        address old = _getRoleAdmin(DEFAULT_ADMIN_ROLE);
        address newAdmin = gu.executeRecovery(GuardianLib.ADMIN_COUNCIL_ID);
        _revokeRole(DEFAULT_ADMIN_ROLE, old);
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _revokeRole(CONTRACT_ADMIN_ROLE, old);
        _grantRole(CONTRACT_ADMIN_ROLE, newAdmin);
        _revokeRole(STAKING_ADMIN_ROLE, old);
        _grantRole(STAKING_ADMIN_ROLE, newAdmin);
        _revokeRole(GOVERNANCE_ADMIN_ROLE, old);
        _grantRole(GOVERNANCE_ADMIN_ROLE, newAdmin);
        _revokeRole(BLUECHIP_ADMIN_ROLE, old);
        _grantRole(BLUECHIP_ADMIN_ROLE, newAdmin);
        emit AdminRecovered(newAdmin);
    }

    // -------- Governance --------

    function createProposal(
        bytes32 id,
        GovernanceLib.ProposalType pType,
        uint8 paramTarget,
        address collectionAddress,
        uint256 newValue
    ) external onlyRole(GOVERNANCE_ADMIN_ROLE) {
        g.create(
            g,
            id,
            pType,
            paramTarget,
            collectionAddress,
            newValue,
            _msgSender(),
            g.votingDurationBlocks,
            g.minVotesRequiredScaled
        );
    }

    function vote(bytes32 id, uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        if (tokenIds.length == 0) revert BadParam();
        
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            address collection = registeredCollections[registeredIndex[IERC721(address(this)).ownerOf(tokenId)]];
            uint256 weightScaled = 1 * WEIGHT_SCALE;
            g.vote(g, id, _msgSender(), weightScaled, collection);
        }
    }

    function executeProposal(bytes32 id) external onlyRole(GOVERNANCE_ADMIN_ROLE) {
        GovernanceLib.Proposal memory p = g.validateForExecution(g, id);
        if (p.pType == GovernanceLib.ProposalType.BASE_REWARD) {
            if (p.newValue > maxBaseRewardRate) revert BadParam();
            emit BaseRewardRateUpdated(s.baseRewardRate, p.newValue);
            s.baseRewardRate = p.newValue;
        } else if (p.pType == GovernanceLib.ProposalType.HARVEST_FEE) {
            if (p.newValue > BP_DENOM) revert BadParam();
            emit HarvestFeeUpdated(initialHarvestBurnFeeRate, p.newValue);
            initialHarvestBurnFeeRate = p.newValue;
        } else if (p.pType == GovernanceLib.ProposalType.UNSTAKE_FEE) {
            if (p.newValue > BP_DENOM) revert BadParam();
            emit UnstakeFeeUpdated(unstakeBurnFee, p.newValue);
            unstakeBurnFee = p.newValue;
        } else if (p.pType == GovernanceLib.ProposalType.REGISTRATION_FEE_FALLBACK) {
            emit RegistrationFeeUpdated(collectionRegistrationFee, p.newValue);
            collectionRegistrationFee = p.newValue;
        } else if (p.pType == GovernanceLib.ProposalType.VOTING_PARAM) {
            // target=0 is duration, target=1 is quorum, target=2 is vote cap
            if (p.paramTarget == 0) {
                emit VotingParamUpdated(0, g.votingDurationBlocks, p.newValue);
                g.votingDurationBlocks = p.newValue;
            } else if (p.paramTarget == 1) {
                emit VotingParamUpdated(1, g.minVotesRequiredScaled, p.newValue);
                g.minVotesRequiredScaled = p.newValue;
            } else if (p.paramTarget == 2) {
                if (p.newValue > 100) revert BadParam();
                emit VotingParamUpdated(2, g.collectionVoteCapPercent, p.newValue);
                g.collectionVoteCapPercent = p.newValue;
            } else {
                revert BadParam();
            }
        } else if (p.pType == GovernanceLib.ProposalType.TIER_UPGRADE) {
            if (!s.collectionConfigs[p.collectionAddress].registered) revert NotRegistered();
            if (s.collectionConfigs[p.collectionAddress].tier == StakingLib.Tier.BLUECHIP) revert BadParam();
            s.collectionConfigs[p.collectionAddress].tier = StakingLib.Tier.BLUECHIP;
            emit CollectionTierUpgraded(p.collectionAddress, StakingLib.Tier.BLUECHIP);
        } else {
            revert BadParam();
        }
        g.markExecuted(g, id);
        emit ProposalExecuted(id, p.newValue);
    }

    // -------- Public functions --------

    function registerCollection(address collection, uint256 declaredSupply) external whenNotPaused nonReentrant {
        if (_msgSender() == deployerAddress) {
            s.initCollection(s, collection, declaredSupply);
        } else {
            uint256 fee = collectionRegistrationFee;
            if (fee > 0) {
                _burn(_msgSender(), fee);
            }
            s.initCollection(s, collection, declaredSupply);
        }
        registeredCollections.push(collection);
        registeredIndex[collection] = registeredCollections.length - 1;
    }

    function stake(
        address collection,
        uint256[] calldata tokenIds,
        bool isPermanent
    ) external whenNotPaused nonReentrant {
        if (tokenIds.length == 0 || tokenIds.length > 100) revert BatchTooLarge();

        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (lastStakingBlock[_msgSender()] + stakingCooldownBlocks > block.number) revert Cooldown();

            if (isPermanent) {
                IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);
                s.recordPermanentStake(s, collection, _msgSender(), tokenId, block.number, rewardRateIncrementPerNFT);
            } else {
                IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);
                s.recordTermStake(s, collection, _msgSender(), tokenId, block.number, termDurationBlocks, rewardRateIncrementPerNFT);
            }

            lastStakingBlock[_msgSender()] = block.number;
            emit NFTStaked(_msgSender(), collection, tokenId, isPermanent);
        }
    }

    function unstake(
        address collection,
        uint256[] calldata tokenIds,
        bool force
    ) external whenNotPaused nonReentrant {
        if (tokenIds.length == 0 || tokenIds.length > 100) revert BatchTooLarge();
        
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            StakingLib.StakeInfo storage info = s.stakeLog[collection][_msgSender()][tokenId];
            if (!info.currentlyStaked) revert NotStaked();
            if (!info.isPermanent && !force && block.number < info.unstakeDeadlineBlock) revert TermNotExpired();

            if (force && !info.isPermanent) revert BadParam();
            if (!info.isPermanent && block.number < info.unstakeDeadlineBlock) revert TermNotExpired();

            if (unstakeBurnFee > 0) {
                uint256 feeAmount = (unstakeBurnFee * 1) / BP_DENOM;
                if (balanceOf(_msgSender()) < feeAmount) revert Insufficient();
                _burn(_msgSender(), feeAmount);
                burnedCatalystByAddress[_msgSender()] += feeAmount;
            }

            s.recordUnstake(s, collection, _msgSender(), tokenId, rewardRateIncrementPerNFT);
            IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);

            emit NFTUnstaked(_msgSender(), collection, tokenId);
        }
    }

    function harvest(
        address collection,
        uint256[] calldata tokenIds
    ) external whenNotPaused nonReentrant {
        if (tokenIds.length == 0 || tokenIds.length > MAX_HARVEST_BATCH) revert BatchTooLarge();

        uint256 totalReward;
        uint256 totalBurned;

        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            uint256 rewardAmount = s.pendingRewards(s, collection, _msgSender(), tokenId, numberOfBlocksPerRewardUnit);
            if (rewardAmount == 0) continue;
            
            uint256 harvestBurnFee = initialHarvestBurnFeeRate;
            uint256 burnAmount = (rewardAmount * harvestBurnFee) / BP_DENOM;
            uint256 mintAmount = rewardAmount - burnAmount;

            _mint(_msgSender(), mintAmount);
            totalReward += mintAmount;
            totalBurned += burnAmount;
            burnedCatalystByAddress[address(0)] += burnAmount; // Burn to zero address
            s.updateLastHarvest(s, collection, _msgSender(), tokenId);
        }
        
        if (totalReward > 0) {
            emit RewardsHarvested(_msgSender(), collection, totalReward, totalBurned);
        }
    }

    function setBluechipCollection(address collection, bool isBluechip) external onlyRole(BLUECHIP_ADMIN_ROLE) {
        b.isBluechipCollection[collection] = isBluechip;
        emit BluechipCollectionSet(collection, isBluechip);
    }
    
    function setCollectionRegistrationFee(uint256 newFee) external onlyRole(STAKING_ADMIN_ROLE) {
        collectionRegistrationFee = newFee;
    }
    
    function setTermDuration(uint256 newDuration) external onlyRole(STAKING_ADMIN_ROLE) {
        termDurationBlocks = newDuration;
    }

    function setRewardRateIncrement(uint256 newRate) external onlyRole(STAKING_ADMIN_ROLE) {
        rewardRateIncrementPerNFT = newRate;
    }

    function setStakingCooldown(uint256 newCooldown) external onlyRole(STAKING_ADMIN_ROLE) {
        stakingCooldownBlocks = newCooldown;
    }
    
    function withdrawTreasury() external onlyAdmin {
        uint256 amount = treasuryBalance;
        if (amount == 0) revert Insufficient();
        treasuryBalance = 0;
        _mint(_msgSender(), amount);
        emit TreasuryWithdrawal(_msgSender(), amount);
    }

    function depositTreasury(uint256 amount) external onlyRole(STAKING_ADMIN_ROLE) {
        treasuryBalance += amount;
        emit TreasuryDeposit(_msgSender(), amount);
    }
    
    // -------- Blue-chip functions --------

    function enrollBluechip() external whenNotPaused nonReentrant {
        b.enroll(b, address(0), _msgSender(), block.number, b.bluechipWalletFee, _mint);
    }

    function harvestBluechipRewards() external whenNotPaused nonReentrant {
        b.harvest(b, address(0), _msgSender(), block.number, s.baseRewardRate, numberOfBlocksPerRewardUnit, _mint);
    }

    // -------- Getters --------

    function checkIsStaked(address owner, address collection, uint256 tokenId) external view returns (bool) {
        return s.stakeLog[collection][owner][tokenId].currentlyStaked;
    }
    
    function checkIsBluechipEnrolled(address wallet) external view returns (bool) {
        return b.bluechipWallets[address(0)][wallet].enrolled;
    }

    /// @notice Returns the total number of NFTs staked in a given collection
    function collectionTotalStaked(address collection) external view returns (uint256) {
        return s.collectionTotalStaked[collection];
    }

    /// @notice Returns true if a collection is flagged as blue-chip
    function isBluechipCollection(address collection) public view returns (bool) {
        return b.isBluechipCollection[collection];
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
    function onERC721Received(address, address from, uint256, bytes calldata) external pure override returns (bytes4) {
        if (from == address(0)) {
            return this.onERC721Received.selector;
        }
        return this.onERC721Received.selector;
    }

    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private __gap;
}
