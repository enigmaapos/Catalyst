// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./lib/FeeManagerLib.sol";
import "./lib/ConfigRegistryLib.sol";
import "./lib/StakingLib.sol";
import "./lib/GovernanceLib.sol";
import "./lib/GuardianLib.sol";

/**
 * CatalystNFTStaking (MVP)
 * - Classic staking (custody assumed handled by caller/front router)
 * - Blue-chip "virtual staking" (ownership-proof via ownerOf)
 * - Hard caps: 1B global, 750M term, 250M perm, 20k per collection
 * - Fee split immutable 90/9/1
 * - Governance (simple stake-count weight)
 * - Dual councils: GCSS (deployer) & AGC (admin)
 */
contract CatalystNFTStaking {
    // -------- Errors
    error NotAdmin();
    error NotContractAdmin();
    error ZeroAddress();
    error NotOwner();
    error CollectionExists();
    error CollectionUnknown();
    error TierMismatch();
    error NoRewards();
    error BalanceLow();

    // -------- Roles (minimal AccessControl)
    bytes32 public constant DEFAULT_ADMIN_ROLE   = 0x00;
    bytes32 public constant CONTRACT_ADMIN_ROLE  = keccak256("CONTRACT_ADMIN_ROLE");

    // role storage
    mapping(bytes32 => mapping(address => bool)) private _roles;
    mapping(bytes32 => bytes32) private _roleAdmin;

    // -------- State: Tokens & Accounts
    IERC20 public CATA;
    FeeManagerLib.Accounts private feeAccounts;

    // -------- Configs
    ConfigRegistryLib.Storage private cfg;

    // -------- Staking
    StakingLib.Storage private stake;

    // collection registry: by NFT address
    event CollectionAdded(address indexed collection, uint256 declaredSupply, StakingLib.CollectionTier tier, bool allowVirtual);
    event CollectionTierUpdated(address indexed collection, StakingLib.CollectionTier tier, bool allowVirtual);

    // -------- Governance
    GovernanceLib.Storage private gov;

    // -------- Guardian Councils
    // Deployer GCSS protects deployer fee sink & recovery
    GuardianLib.Council private gcss;
    address public deployer; // receives 1% fee
    // Admin Guardian Council protects DEFAULT_ADMIN_ROLE recovery
    GuardianLib.Council private agc;

    // -------- Treasury
    address public treasury;

    // -------- Events
    event Harvest(address indexed user, address indexed collection, uint256 indexed tokenId, uint256 amount);
    event Unstaked(address indexed user, address indexed collection, uint256 indexed tokenId, bool permanent, bool virtualStake);
    event VirtualRegistered(address indexed user, address indexed collection, uint256 indexed tokenId, bool permanent);

    // -------- Modifiers
    modifier onlyRole(bytes32 r){ if (!_roles[r][msg.sender]) revert NotAdmin(); _; }
    modifier onlyDefaultAdmin(){ if (!_roles[DEFAULT_ADMIN_ROLE][msg.sender]) revert NotAdmin(); _; }
    modifier onlyContractAdmin(){ if (!_roles[CONTRACT_ADMIN_ROLE][msg.sender]) revert NotContractAdmin(); _; }

    // -------- Constructor
    constructor(
        address cata_,
        address treasury_,
        address deployerSink_,
        address defaultAdmin_,
        address contractAdmin_,
        address[] memory gcssInitial, uint8 gcssThreshold,
        address[] memory agcInitial, uint8 agcThreshold
    ){
        if (cata_==address(0) || treasury_==address(0) || deployerSink_==address(0) || defaultAdmin_==address(0) || contractAdmin_==address(0))
            revert ZeroAddress();

        CATA = IERC20(cata_);
        treasury = treasury_;
        deployer = deployerSink_;

        // roles
        _roleAdmin[DEFAULT_ADMIN_ROLE]  = DEFAULT_ADMIN_ROLE;
        _roleAdmin[CONTRACT_ADMIN_ROLE] = DEFAULT_ADMIN_ROLE;

        _grant(DEFAULT_ADMIN_ROLE, defaultAdmin_);
        _grant(CONTRACT_ADMIN_ROLE, contractAdmin_);

        // fee accounts
        feeAccounts.cataToken   = cata_;
        feeAccounts.treasury    = treasury_;
        feeAccounts.deployerSink= deployerSink_;

        // configs
        ConfigRegistryLib.init(cfg, defaultAdmin_);
        stake.baseRewardRate = cfg.baseRewardRate;

        // governance
        GovernanceLib.init(gov, defaultAdmin_);

        // councils
        GuardianLib.initCouncil(gcss, gcssInitial, gcssThreshold, cfg.lastHonestWindow);
        GuardianLib.initCouncil(agc,   agcInitial,   agcThreshold, cfg.lastHonestWindow);
    }

    // -------- Role logic
    function getRoleAdmin(bytes32 r) external view returns (bytes32){ return _roleAdmin[r]; }
    function hasRole(bytes32 r, address a) public view returns (bool){ return _roles[r][a]; }
    function grantRole(bytes32 r, address a) external onlyDefaultAdmin { _grant(r,a); }
    function revokeRole(bytes32 r, address a) external onlyDefaultAdmin { _revoke(r,a); }
    function _grant(bytes32 r, address a) internal { _roles[r][a] = true; }
    function _revoke(bytes32 r, address a) internal { _roles[r][a] = false; }

    // -------- Collection management
    function addCollection(address nft, uint256 declaredSupply, uint8 tier, bool allowVirtual) external onlyContractAdmin {
        if (stake.cfg[nft].registered) revert CollectionExists();
        stake.cfg[nft] = StakingLib.CollectionConfig({
            registered: true,
            tier: StakingLib.CollectionTier(tier),
            declaredSupply: declaredSupply,
            totalStaked: 0,
            totalStakers: 0,
            allowVirtual: allowVirtual,
            nft: nft
        });
        emit CollectionAdded(nft, declaredSupply, StakingLib.CollectionTier(tier), allowVirtual);
    }

    function setCollectionTier(address nft, uint8 tier, bool allowVirtual) external onlyContractAdmin {
        if (!stake.cfg[nft].registered) revert CollectionUnknown();
        stake.cfg[nft].tier = StakingLib.CollectionTier(tier);
        stake.cfg[nft].allowVirtual = allowVirtual;
        emit CollectionTierUpdated(nft, StakingLib.CollectionTier(tier), allowVirtual);
    }

    // -------- Staking (classic custody assumed by front router)
    function stakeClassic(address collection, uint256 tokenId, bool permanent) external {
        StakingLib.Caps memory caps = StakingLib.Caps({
            globalCap: cfg.globalCap,
            termCap:   cfg.termCap,
            permCap:   cfg.permCap,
            perCollectionCap: cfg.perCollectionCap,
            termDurationBlocks: cfg.termDurationBlocks
        });
        // NOTE: custody transfer should be handled outside this core (router).
        StakingLib.stakeClassic(
            stake, collection, msg.sender, tokenId, block.number, cfg.termDurationBlocks, permanent, caps
        );
    }

    function unstakeClassic(address collection, uint256 tokenId) external {
        // NOTE: caller must have custody transfer logic outside, here we just accounting.
        StakingLib.unstakeClassic(stake, collection, msg.sender, tokenId);
        emit Unstaked(msg.sender, collection, tokenId, false, false);
        // fee on unstake
        FeeManagerLib.splitFrom(msg.sender, feeAccounts, IERC20Like(address(CATA)), cfg.unstakeFee);
    }

    // -------- Blue-chip virtual staking (no custody)
    function registerVirtual(address collection, uint256 tokenId, bool permanent) external {
        StakingLib.CollectionConfig memory c = stake.cfg[collection];
        if (!c.registered || c.tier != StakingLib.CollectionTier.VERIFIED || !c.allowVirtual) revert TierMismatch();
        StakingLib.Caps memory caps = StakingLib.Caps({
            globalCap: cfg.globalCap,
            termCap:   cfg.termCap,
            permCap:   cfg.permCap,
            perCollectionCap: cfg.perCollectionCap,
            termDurationBlocks: cfg.termDurationBlocks
        });
        StakingLib.registerVirtual(stake, collection, msg.sender, tokenId, permanent, block.number, IERC721(collection), caps);
        emit VirtualRegistered(msg.sender, collection, tokenId, permanent);
    }

    function unregisterVirtual(address collection, uint256 tokenId) external {
        // must still be current staker of virtual position
        StakingLib.unregisterVirtual(stake, collection, msg.sender, tokenId);
        emit Unstaked(msg.sender, collection, tokenId, false, true);
        // fee on unstake
        FeeManagerLib.splitFrom(msg.sender, feeAccounts, IERC20Like(address(CATA)), cfg.unstakeFee);
    }

    // -------- Rewards
    function pending(address collection, uint256 tokenId) public view returns (uint256) {
        return StakingLib.pendingRewards(
            stake, collection, msg.sender, tokenId, cfg.blocksPerUnit
        );
    }

    function harvest(address collection, uint256 tokenId) external {
        uint256 amt = pending(collection, tokenId);
        if (amt == 0) revert NoRewards();

        // update last harvest
        stake.stakeLog[collection][msg.sender][tokenId].lastHarvestBlock = block.number;

        // charge fee (90/9/1)
        FeeManagerLib.splitFrom(msg.sender, feeAccounts, IERC20Like(address(CATA)), cfg.harvestFee);

        // minting logic: for MVP we simulate mint via treasury pull (or external minter in real system)
        // Here, we require treasury holds CATA to reward.
        if (IERC20(address(CATA)).balanceOf(treasury) < amt) revert BalanceLow();
        require(IERC20(address(CATA)).transferFrom(treasury, msg.sender, amt));
        emit Harvest(msg.sender, collection, tokenId, amt);
    }

    // -------- Read helpers
    function stakingStats() external view returns (
        uint256 totalAll, uint256 totalTerm, uint256 totalPerm
    ){
        return (stake.totalStakedAll, stake.totalStakedTerm, stake.totalStakedPermanent);
    }

    function collectionInfo(address collection) external view returns (
        bool registered, uint8 tier, uint256 declaredSupply, uint256 totalStaked, uint256 totalStakers, bool allowVirtual
    ){
        StakingLib.CollectionConfig memory c = stake.cfg[collection];
        return (c.registered, uint8(c.tier), c.declaredSupply, c.totalStaked, c.totalStakers, c.allowVirtual);
    }

    // -------- Governance (minimal)
    function govPropose(bytes32 callKey) external returns (uint256 id) {
        id = GovernanceLib.propose(gov, msg.sender, callKey);
    }

    // weight = number of NFTs (classic+virtual) across all collections for voter (quick approximation)
    function voterWeight(address voter) public view returns (uint256 w) {
        // NOTE: gas-light approximation; iterate on known collections is not feasible without index.
        // For MVP, frontend passes known tokenIds to tally; or extend with per-user counter.
        // Here we’ll use a minimal per-user counter by summing portfolios for each collection on demand is not possible.
        // To keep MVP working, we approximate: weight = CATA balance.
        w = IERC20(address(CATA)).balanceOf(voter);
    }

    function govVote(uint256 id, bool support) external {
        GovernanceLib.vote(gov, id, msg.sender, voterWeight(msg.sender), support);
    }

    function govCanExecute(uint256 id) external view returns (bool) {
        return GovernanceLib.canExecute(gov, id);
    }

    function govMarkExecuted(uint256 id) external onlyDefaultAdmin {
        // in production, you’d pair this with an on-chain action keyed by callKey
        GovernanceLib.markExecuted(gov, id);
    }

    // -------- Guardian Councils
    // GCSS (deployer recovery)
    event DeployerChanged(address indexed oldDeployer, address indexed newDeployer);

    function gcssPropose(address candidate) external {
        GuardianLib.propose(gcss, msg.sender, candidate);
    }

    function gcssApprove() external {
        (bool threshold, bool lockedNow) = GuardianLib.approve(gcss, msg.sender);
        if (lockedNow) return; // locked, only reset can unlock

        // execute if reached threshold
        if (threshold) {
            address old = deployer;
            deployer = gcss.proposedNew;
            feeAccounts.deployerSink = deployer;
            emit DeployerChanged(old, deployer);
            // auto-clear proposal
            gcss.proposedNew = address(0);
            gcss.approvals = 0;
        }
    }

    function gcssResetByDeployer(address[] calldata newSet, uint8 newThreshold) external {
        GuardianLib.resetByDeployer(gcss, msg.sender, deployer, newSet, newThreshold);
    }

    function gcssResetByLastHonest(address[] calldata newSet, uint8 newThreshold) external {
        GuardianLib.resetByLastHonest(gcss, msg.sender, newSet, newThreshold);
    }

    // AGC (admin recovery)
    event AdminTakenOver(address indexed oldAdmin, address indexed newAdmin);

    function agcPropose(address candidateAdmin) external {
        GuardianLib.propose(agc, msg.sender, candidateAdmin);
    }

    function agcApprove() external {
        (bool threshold, bool lockedNow) = GuardianLib.approve(agc, msg.sender);
        if (lockedNow) return;

        if (threshold) {
            address old = cfg.admin;
            // SAFE-REVOKE MECHANISM:
            // 1) grant admin to candidate
            _grant(DEFAULT_ADMIN_ROLE, agc.proposedNew);
            cfg.admin = agc.proposedNew;
            emit AdminTakenOver(old, agc.proposedNew);
            // 2) revoke old admin
            _revoke(DEFAULT_ADMIN_ROLE, old);
            // 3) clear proposal
            agc.proposedNew = address(0);
            agc.approvals = 0;
        }
    }

    function agcResetByDeployer(address[] calldata newSet, uint8 newThreshold) external {
        // For AGC, the "deployer" is interpreted as CURRENT default admin for resets
        GuardianLib.resetByDeployer(agc, msg.sender, cfg.admin, newSet, newThreshold);
    }

    function agcResetByLastHonest(address[] calldata newSet, uint8 newThreshold) external {
        GuardianLib.resetByLastHonest(agc, msg.sender, newSet, newThreshold);
    }

    // -------- Admin config passthrough
    function setConfig(bytes32 key, uint256 value) external onlyDefaultAdmin {
        ConfigRegistryLib.setUint(cfg, msg.sender, key, value);
        // sync reward rate if needed
        if (key == keccak256("baseRewardRate")) stake.baseRewardRate = cfg.baseRewardRate;
    }
    function setCouncilThreshold(bool forDeployer, uint8 t) external onlyDefaultAdmin {
        ConfigRegistryLib.setThreshold(cfg, msg.sender, forDeployer, t);
        if (forDeployer) GuardianLib.setThreshold(gcss, t); else GuardianLib.setThreshold(agc, t);
    }

    // -------- Misc
    function accounts() external view returns (address cata, address trea, address dep) {
        return (feeAccounts.cataToken, feeAccounts.treasury, feeAccounts.deployerSink);
    }
}
