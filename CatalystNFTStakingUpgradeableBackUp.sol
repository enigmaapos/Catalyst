// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StakingLib.sol";
import "./GovernanceLib.sol";

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC721/IERC721Receiver.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC721/IERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/security/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/token/ERC20/IERC20.sol";

interface IOwnable { function owner() external view returns (address); }

contract CatalystNFTStaking is ERC20, AccessControl, IERC721Receiver, ReentrancyGuard, Pausable {
    using StakingLib for StakingLib.Storage;

    // roles
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // fee split
    uint256 public constant BURN_BP = 9000;
    uint256 public constant TREASURY_BP = 900;
    uint256 public constant DEPLOYER_BP = 100;

    // internal treasury accounting
    uint256 public treasuryBalance;

    // constants
    uint256 public constant WEIGHT_SCALE = 1e18;
    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public constant MAX_STAKE_PER_COLLECTION = 20000;

    // tiers
    enum CollectionTier { UNVERIFIED, VERIFIED }

    // staking lib storage
    StakingLib.Storage internal s;

    // governance lib storage
    GovernanceLib.Storage internal g;

    // other params
    uint256 public numberOfBlocksPerRewardUnit = 18782;
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
    uint256 public SMALL_MIN_FEE = 1000 * 10**18;
    uint256 public SMALL_MAX_FEE = 5000 * 10**18;
    uint256 public MED_MIN_FEE   = 5000 * 10**18;
    uint256 public MED_MAX_FEE   = 10000 * 10**18;
    uint256 public LARGE_MIN_FEE = 10000 * 10**18;
    uint256 public LARGE_MAX_FEE_CAP = 20000 * 10**18;

    uint256 public unverifiedSurchargeBP = 20000;
    uint256 public tierUpgradeMinAgeBlocks = 200000;
    uint256 public tierUpgradeMinBurn = 50_000 * 10**18;
    uint256 public tierUpgradeMinStakers = 50;
    uint256 public tierProposalCooldownBlocks = 30000;
    uint256 public surchargeForfeitBlocks = 600000;

    // minimal registration enumeration
    address[] public registeredCollections;
    mapping(address => uint256) public registeredIndex;

    // burner bookkeeping
    mapping(address => uint256) public burnedCatalystByAddress;
    mapping(address => uint256) public lastBurnBlock;
    mapping(address => bool) public isParticipating;
    address[] public participatingWallets;

    // ---------------- Deployer & Backup System ----------------
    address public deployerAddress;
    mapping(address => bool) public isBackupDeployer;
    address[] private _backupList;
    mapping(address => uint256) private _backupIndex;

    // backup events
    event BackupAdded(address indexed backup);
    event BackupRemoved(address indexed backup);
    event DeployerRecovered(address indexed oldDeployer, address indexed newDeployer, address indexed byBackup);

    // staking events
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payoutAmount, uint256 burnedAmount);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);
    event CollectionAdded(address indexed collection, uint256 declaredSupply, uint256 baseFee, uint256 surchargeEscrow, CollectionTier tier);

    // constructor config
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
        uint256 votingDurationBlocks;
        uint256 minVotesRequiredScaled;
        uint256 collectionVoteCapPercent;
        address[] backupDeployers; // NEW
    }

    constructor(InitConfig memory cfg) ERC20("Catalyst", "CATA") {
        require(cfg.owner != address(0) && cfg.treasury != address(0), "CATA: bad addr");

        _mint(cfg.owner, 25_185_000 * 10**18);

        _grantRole(DEFAULT_ADMIN_ROLE, cfg.owner);
        _grantRole(CONTRACT_ADMIN_ROLE, cfg.owner);

        treasuryAddress = address(this);
        deployerAddress = cfg.owner;

        // seed backups
        for (uint256 i = 0; i < cfg.backupDeployers.length; i++) {
            address b = cfg.backupDeployers[i];
            if (b != address(0) && !isBackupDeployer[b]) {
                isBackupDeployer[b] = true;
                _backupIndex[b] = _backupList.length + 1;
                _backupList.push(b);
                emit BackupAdded(b);
            }
        }

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

        GovernanceLib.initGov(
            g,
            cfg.votingDurationBlocks,
            cfg.minVotesRequiredScaled,
            cfg.collectionVoteCapPercent
        );
    }

    // ---------------- Backup-only recovery system ----------------
    modifier onlyBackup() {
        require(isBackupDeployer[_msgSender()], "CATA: not backup");
        _;
    }

    function getBackups() external view returns (address[] memory) {
        return _backupList;
    }

    function addBackup(address newBackup) external onlyBackup {
        require(newBackup != address(0), "CATA: zero");
        require(!isBackupDeployer[newBackup], "CATA: exists");
        isBackupDeployer[newBackup] = true;
        _backupIndex[newBackup] = _backupList.length + 1;
        _backupList.push(newBackup);
        emit BackupAdded(newBackup);
    }

    function removeBackup(address backup) external {
        require(_msgSender() == backup, "CATA: self-only");
        require(isBackupDeployer[backup], "CATA: not backup");
        isBackupDeployer[backup] = false;

        uint256 idx1 = _backupIndex[backup];
        if (idx1 != 0) {
            uint256 i = idx1 - 1;
            uint256 last = _backupList.length - 1;
            if (i != last) {
                address lastAddr = _backupList[last];
                _backupList[i] = lastAddr;
                _backupIndex[lastAddr] = i + 1;
            }
            _backupList.pop();
            _backupIndex[backup] = 0;
        }
        emit BackupRemoved(backup);
    }

    function recoverDeployer(address newDeployer) external onlyBackup {
        require(newDeployer != address(0), "CATA: zero");
        require(newDeployer != deployerAddress, "CATA: same");

        address old = deployerAddress;
        deployerAddress = newDeployer;
        emit DeployerRecovered(old, newDeployer, _msgSender());
    }


    // ------------- modifiers -------------
    mapping(address => uint256) public lastStakingBlock;
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: cooldown");
        _;
    }

    // ------------- Helpers -------------
    function _splitFeeFromSender(address payer, uint256 amount, bool /*attributeToUser*/) internal {
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

    // ------------- Registration -------------
    function registerCollection(address collection, uint256 declaredMaxSupply, CollectionTier /*requestedTier*/) external nonReentrant whenNotPaused {
        require(collection != address(0), "CATA: bad addr");
        require(registeredIndex[collection] == 0, "CATA: already reg");
        require(declaredMaxSupply >= 1 && declaredMaxSupply <= MAX_STAKE_PER_COLLECTION, "CATA: supply range");

        uint256 baseFee = _calculateRegistrationBaseFee(declaredMaxSupply);
        require(balanceOf(_msgSender()) >= baseFee, "CATA: insufficient");

        _splitFeeFromSender(_msgSender(), baseFee, true);

        // direct-call style to lib
        StakingLib.initCollection(s, collection, declaredMaxSupply);

        registeredCollections.push(collection);
        registeredIndex[collection] = registeredCollections.length;

        emit CollectionAdded(collection, declaredMaxSupply, baseFee, 0, CollectionTier.UNVERIFIED);
    }

    // ------------- Staking wrappers -------------
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

        _splitFeeFromSender(_msgSender(), fee, true);

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
        _splitFeeFromSender(_msgSender(), unstakeBurnFee, true);

        StakingLib.recordUnstake(s, collection, _msgSender(), tokenId, rewardRateIncrementPerNFT);

        IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);

        emit NFTUnstaked(_msgSender(), collection, tokenId);
    }

    // ------------- Batch helpers (same behavior) -------------
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

    // ------------- Harvest -------------
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

    // ------------- Governance wrappers (same external API) -------------
    function propose(
        GovernanceLib.ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collectionContext
    ) external whenNotPaused returns (bytes32) {
        bytes32 id = GovernanceLib.createProposal(
            g,
            pType,
            paramTarget,
            newValue,
            collectionContext,
            _msgSender(),
            block.number
        );
        return id;
    }

    function vote(bytes32 id) external whenNotPaused {
        (uint256 weight, address attributedCollection) = _votingWeight(_msgSender(), address(0));
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

    // ------------- Voting weight -------------
    function _votingWeight(address voter, address /*context*/) internal view returns (uint256 weight, address attributedCollection) {
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

    // ------------- math & helper views -------------
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

    // ------------- Treasury -------------
    function withdrawTreasury(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(to != address(0), "CATA: bad addr");
        require(amount <= treasuryBalance, "CATA: balance");
        treasuryBalance -= amount;
        _transfer(address(this), to, amount);
        emit TreasuryWithdrawal(to, amount);
    }

    // ------------- Views -------------
    function pendingRewardsView(address collection, address owner, uint256 tokenId) external view returns (uint256) {
        return StakingLib.pendingRewards(s, collection, owner, tokenId, numberOfBlocksPerRewardUnit);
    }

    function totalStakedNFTs() external view returns (uint256) { return s.totalStakedNFTsCount; }
    function baseReward() external view returns (uint256) { return s.baseRewardRate; }

    // ------------- ERC721 Receiver -------------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ------------- UUPS authorization -------------
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // (optional) storage gap to allow future variable additions without shifting layout
    uint256[45] private __gap; // adjust size if you later add vars above
}
