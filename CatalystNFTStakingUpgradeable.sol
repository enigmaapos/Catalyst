// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin upgradeable bases
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Your modular libraries (must exist in same project)
import "./StakingLib.sol";
import "./GovernanceLib.sol";
import "./ConfigLib.sol";
import "./FeeLib.sol";
import "./TreasuryLib.sol";
import "./ProposalExecLib.sol";

/// @title Catalyst NFT Staking (Lean, Upgradeable Skeleton)
/// @notice Minimal upgradeable staking + governance skeleton; timelock wiring recommended.
contract CatalystNFTStakingUpgradeableLean is
    ERC20Upgradeable,
    AccessControlUpgradeable,
    IERC721ReceiverUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // Roles
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // Library storage structs (kept minimal)
    StakingLib.Storage internal s;
    GovernanceLib.Storage internal g;
    ConfigLib.Storage internal c;
    FeeLib.Storage internal f;
    TreasuryLib.Storage internal t;

    // Minimal state
    address public deployer;

    // Events
    event NFTStaked(address indexed staker, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed staker, address indexed collection, uint256 indexed tokenId);
    event RewardsHarvested(address indexed staker, address indexed collection, uint256 payout, uint256 burned);
    event ProposalCreated(bytes32 indexed id, GovernanceLib.ProposalType pType, uint8 paramTarget, uint256 newValue);
    event ProposalExecuted(bytes32 indexed id);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize (call through proxy)
    function initialize(
        address admin_,
        address deployer_,
        uint256 initialMint,
        uint16 burnBP_,
        uint16 treasuryBP_,
        uint16 deployerBP_,
        uint256 votingDurationBlocks,
        uint256 minVotesScaled,
        uint256 collectionVoteCapPercent
    ) external initializer {
        require(admin_ != address(0) && deployer_ != address(0), "bad addrs");

        __ERC20_init("Catalyst", "CATA");
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CONTRACT_ADMIN_ROLE, admin_);

        deployer = deployer_;
        if (initialMint > 0) _mint(admin_, initialMint);

        // init libs explicitly
        FeeLib.init(f, burnBP_, treasuryBP_, deployerBP_);
        GovernanceLib.initGov(g, votingDurationBlocks, minVotesScaled, collectionVoteCapPercent);

        // set a safe default reward timing (config paramId 12)
        ConfigLib.setUint(c, 12, 18782);
    }

    // ----------------- Staking (minimal) -----------------
    function termStake(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        require(collection != address(0), "bad collection");
        require(s.collectionConfigs[collection].registered, "collection not registered");

        // pull NFT
        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakingLib.recordTermStake(
            s,
            collection,
            _msgSender(),
            tokenId,
            block.number,
            ConfigLib.getUint(c, 15), // termDurationBlocks
            ConfigLib.getUint(c, 21)  // rewardRateIncrementPerNFT
        );

        emit NFTStaked(_msgSender(), collection, tokenId);
    }

    function permanentStake(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        require(collection != address(0), "bad collection");
        require(s.collectionConfigs[collection].registered, "collection not registered");

        uint256 fee = ConfigLib.getUint(c, 19) + (StakingLib.sqrt(s.totalStakedNFTsCount) * ConfigLib.getUint(c, 20));
        require(balanceOf(_msgSender()) >= fee, "insufficient fee");

        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        (uint256 burnAmt, uint256 treasuryAmt, uint256 deployerAmt) = FeeLib.computeSplits(f, fee);
        if (burnAmt > 0) _burn(_msgSender(), burnAmt);
        if (deployerAmt > 0) _transfer(_msgSender(), deployer, deployerAmt);
        if (treasuryAmt > 0) { _transfer(_msgSender(), address(this), treasuryAmt); TreasuryLib.recordDeposit(t, _msgSender(), treasuryAmt); }

        StakingLib.recordPermanentStake(
            s,
            collection,
            _msgSender(),
            tokenId,
            block.number,
            ConfigLib.getUint(c, 21)
        );

        emit NFTStaked(_msgSender(), collection, tokenId);
    }

    function unstake(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        StakingLib.StakeInfo memory info = s.stakeLog[collection][_msgSender()][tokenId];
        require(info.currentlyStaked, "not staked");
        if (!info.isPermanent) require(block.number >= info.unstakeDeadlineBlock, "term active");

        // Harvest pending rewards for this token (minimal handling)
        uint256 reward = StakingLib.pendingRewards(s, collection, _msgSender(), tokenId, ConfigLib.getUint(c, 12));
        uint256 burned = 0;
        if (reward > 0) {
            uint256 feeRate = _getDynamicHarvestBurnFeeRate();
            burned = (reward * feeRate) / 100;
            _mint(_msgSender(), reward);
            if (burned > 0) _burn(_msgSender(), burned);
            StakingLib.updateLastHarvest(s, collection, _msgSender(), tokenId);
            emit RewardsHarvested(_msgSender(), collection, reward - burned, burned);
        }

        uint256 unstakeFee = ConfigLib.getUint(c, 26);
        if (unstakeFee > 0) {
            (uint256 b2, uint256 tr2, uint256 d2) = FeeLib.computeSplits(f, unstakeFee);
            if (b2 > 0) _burn(_msgSender(), b2);
            if (d2 > 0) _transfer(_msgSender(), deployer, d2);
            if (tr2 > 0) { _transfer(_msgSender(), address(this), tr2); TreasuryLib.recordDeposit(t, _msgSender(), tr2); }
        }

        StakingLib.recordUnstake(s, collection, _msgSender(), tokenId, ConfigLib.getUint(c, 21));
        IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);

        emit NFTUnstaked(_msgSender(), collection, tokenId);
    }

    // ----------------- Harvest -----------------
    function harvest(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        uint256 reward = StakingLib.pendingRewards(s, collection, _msgSender(), tokenId, ConfigLib.getUint(c, 12));
        require(reward > 0, "no reward");
        uint256 feeRate = _getDynamicHarvestBurnFeeRate();
        uint256 burned = (reward * feeRate) / 100;
        _mint(_msgSender(), reward);
        if (burned > 0) _burn(_msgSender(), burned);
        StakingLib.updateLastHarvest(s, collection, _msgSender(), tokenId);
        emit RewardsHarvested(_msgSender(), collection, reward - burned, burned);
    }

    // ----------------- Governance (thin) -----------------
    function propose(
        GovernanceLib.ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collectionContext
    ) external whenNotPaused returns (bytes32) {
        bytes32 id = GovernanceLib.createProposal(g, pType, paramTarget, newValue, collectionContext, _msgSender(), block.number);
        emit ProposalCreated(id, pType, paramTarget, newValue);
        return id;
    }

    function vote(bytes32 proposalId) external whenNotPaused {
        // minimal weight: use simple scaled weight or a helper in your StakingLib; here we call a simple method
        // Example: 1 vote per eligible staker (you can expand)
        uint256 weight = 1;
        GovernanceLib.castVote(g, proposalId, _msgSender(), weight, address(0));
    }

    function executeProposal(bytes32 proposalId) external whenNotPaused {
        GovernanceLib.Proposal memory p = GovernanceLib.validateForExecution(g, proposalId);
        ProposalExecLib.applyProposal(g, s, c, proposalId, p);
        GovernanceLib.markExecuted(g, proposalId);
        emit ProposalExecuted(proposalId);
    }

    // ----------------- Config & Fee helpers -----------------
    function updateConfig(uint8 paramId, uint256 newValue) external onlyRole(CONTRACT_ADMIN_ROLE) {
        ConfigLib.setUint(c, paramId, newValue);
    }

    function getConfig(uint8 paramId) external view returns (uint256) {
        return ConfigLib.getUint(c, paramId);
    }

    function handleFeeFromSender(address from, uint256 amount) external nonReentrant {
        (uint256 b, uint256 tr, uint256 d) = FeeLib.computeSplits(f, amount);
        if (b > 0) _burn(from, b);
        if (tr > 0) { _transfer(from, address(this), tr); TreasuryLib.recordDeposit(t, from, tr); }
        if (d > 0) _transfer(from, deployer, d);
    }

    // ----------------- Treasury -----------------
    function treasuryBalance() external view returns (uint256) {
        return TreasuryLib.balanceOf(t);
    }

    function withdrawTreasury(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant {
        TreasuryLib.recordWithdrawal(t, to, amount);
        _transfer(address(this), to, amount);
    }

    // ----------------- Helpers & Views -----------------
    function _getDynamicHarvestBurnFeeRate() public view returns (uint256) {
        uint256 initial = ConfigLib.getUint(c, 14);
        uint256 adj = ConfigLib.getUint(c, 17);
        if (adj == 0) return initial;
        // minimal: no per-user burn tracking in skeleton
        return initial;
    }

    function pendingRewardsView(address collection, address owner, uint256 tokenId) external view returns (uint256) {
        return StakingLib.pendingRewards(s, collection, owner, tokenId, ConfigLib.getUint(c, 12));
    }

    // ----------------- ERC721 receiver -----------------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ----------------- Admin -----------------
    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }

    // ----------------- UUPS authorization (Timelock should be DEFAULT_ADMIN_ROLE) -----------------
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
