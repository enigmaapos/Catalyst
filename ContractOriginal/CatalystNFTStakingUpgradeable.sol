// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin (v5) upgradeable + access control
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Local libs
import {StakingLib} from "./lib/StakingLib.sol";
import {GovernanceLib} from "./lib/GovernanceLib.sol";
import {DRSLib} from "./lib/DRSLib.sol";

/// @notice Minimal CATA token interface the core needs (mint/burn/transfer)
interface ICataToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

/// @notice Compile-ready, minimal, upgradeable core that wires libraries together.
contract CatalystNFTStakingUpgradeable is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using StakingLib for StakingLib.Storage;
    using GovernanceLib for GovernanceLib.Storage;
    using DRSLib for DRSLib.Council;

    // ---- Roles ----
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // ---- Storage ----
    ICataToken public cata;
    address    public treasury;
    address    public deployerPayout; // receives immutable 1% fee share (governance cannot change logic; address can rotate via DRS)

    // Library-backed state
    StakingLib.Storage private S;
    GovernanceLib.Storage private G;

    // Guardian councils (GCSS & AGC)
    DRSLib.Council private deployerCouncil; // protects deployerPayout rotation
    DRSLib.Council private adminCouncil;    // protects DEFAULT_ADMIN_ROLE via recovery

    // ---- Config (examples / compile-ready) ----
    uint256 public constant BLOCKS_PER_REWARD_UNIT = 7200; // ~1 day on 12s blocks
    uint256 public rewardRateIncrementPerNFT;              // simple linear weight

    // ---- Errors ----
    error NotOwnerOrAdmin();
    error NotCollectionOwner();
    error ZeroAddress();
    error NotGuardian();

    // ---- Events ----
    event Staked(address indexed collection, address indexed owner, uint256 indexed tokenId, bool permanent_);
    event Unstaked(address indexed collection, address indexed owner, uint256 indexed tokenId);
    event Harvested(address indexed collection, address indexed owner, uint256 indexed tokenId, uint256 reward);
    event CollectionRegistered(address indexed collection, uint256 declaredSupply);

    // ---- Initializer ----
    function initialize(
        address cataToken,
        address treasury_,
        address deployerPayout_,
        address[] calldata gcssGuardians, uint8 gcssThreshold, uint64 gcssWindowBlocks,
        address[] calldata agcGuardians,  uint8 agcThreshold,  uint64 agcWindowBlocks
    ) external initializer {
        if (cataToken == address(0) || treasury_ == address(0) || deployerPayout_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        cata = ICataToken(cataToken);
        treasury = treasury_;
        deployerPayout = deployerPayout_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONTRACT_ADMIN_ROLE, msg.sender);

        // simple gov init (you can tune later)
        G.init(/*minBlocks*/ 20_000, /*quorum*/ 1_000);

        // councils
        deployerCouncil.init(gcssGuardians, gcssThreshold, gcssWindowBlocks);
        adminCouncil.init(agcGuardians, agcThreshold, agcWindowBlocks);

        rewardRateIncrementPerNFT = 1e18; // placeholder units
    }

    // ---- UUPS auth ----
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ---- Staking (compile-ready happy path) ----

    function registerCollection(address collection, uint256 declaredSupply) external onlyRole(CONTRACT_ADMIN_ROLE) {
        S.initCollection(collection, declaredSupply);
        emit CollectionRegistered(collection, declaredSupply);
    }

    function stake(address collection, uint256 tokenId, bool permanent_) external nonReentrant {
        IERC721 nft = IERC721(collection);
        require(nft.ownerOf(tokenId) == msg.sender, "NOT_OWNER");
        nft.transferFrom(msg.sender, address(this), tokenId);

        if (permanent_) {
            S.recordPermanentStake(collection, msg.sender, tokenId, block.number, rewardRateIncrementPerNFT);
        } else {
            // example 30-day term
            S.recordTermStake(collection, msg.sender, tokenId, block.number, 30 days / 12, rewardRateIncrementPerNFT);
        }

        emit Staked(collection, msg.sender, tokenId, permanent_);
    }

    function unstake(address collection, uint256 tokenId) external nonReentrant {
        StakingLib.StakeInfo memory info = S.stakeLog[collection][msg.sender][tokenId];
        require(info.currentlyStaked, "NOT_STAKED");
        // return NFT first
        IERC721(collection).transferFrom(address(this), msg.sender, tokenId);
        S.recordUnstake(collection, msg.sender, tokenId, rewardRateIncrementPerNFT);
        emit Unstaked(collection, msg.sender, tokenId);
    }

    function harvest(address collection, uint256 tokenId) external nonReentrant {
        uint256 reward = S.pendingRewards(collection, msg.sender, tokenId, BLOCKS_PER_REWARD_UNIT);
        require(reward > 0, "NO_REWARD");
        S.updateLastHarvest(collection, msg.sender, tokenId);
        // mint reward
        cata.mint(msg.sender, reward);
        emit Harvested(collection, msg.sender, tokenId, reward);
    }

    // ---- Views ----

    /// @notice One-call stats to power UI (term vs permanent vs global).
    function stakingStats() external view returns (
        uint256 totalAll,
        uint256 totalTerm,
        uint256 totalPermanent,
        uint256 baseRewardRate,
        uint256 globalCap,
        uint256 termCap,
        uint256 permCap
    ) {
        return (
            S.totalStakedAll,
            S.totalStakedTerm,
            S.totalStakedPermanent,
            S.baseRewardRate,
            StakingLib.GLOBAL_CAP,
            StakingLib.TERM_CAP,
            StakingLib.PERM_CAP
        );
    }

    // ---- DRS: GCSS (deployer payout rotation) ----

    function gcssPropose(address newDeployerPayout) external {
        if (!deployerCouncil.isGuardian(msg.sender)) revert NotGuardian();
        deployerCouncil.proposeRecovery(msg.sender, newDeployerPayout);
    }

    function gcssApprove() external {
        if (!deployerCouncil.isGuardian(msg.sender)) revert NotGuardian();
        deployerCouncil.approveRecovery(msg.sender);
    }

    function gcssExecute() external {
        // anyone can trigger once threshold is met; council enforces threshold
        address newTarget = deployerCouncil.executeRecovery(deployerCouncil.threshold);
        deployerPayout = newTarget;
    }

    function gcssOwnerReset(address[] calldata newGuardians, uint8 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        deployerCouncil.ownerResetGuardians(newGuardians, newThreshold);
    }

    function gcssLastHonestReset(address[] calldata newGuardians, uint8 newThreshold) external {
        deployerCouncil.lastHonestResetGuardians(msg.sender, newGuardians, newThreshold);
    }

    // ---- DRS: AGC (admin role recovery) ----
    // Pattern: recovery assigns DEFAULT_ADMIN_ROLE to a new account, then safe-revokes the old one.

    function agcPropose(address newAdmin) external {
        if (!adminCouncil.isGuardian(msg.sender)) revert NotGuardian();
        adminCouncil.proposeRecovery(msg.sender, newAdmin);
    }

    function agcApprove() external {
        if (!adminCouncil.isGuardian(msg.sender)) revert NotGuardian();
        adminCouncil.approveRecovery(msg.sender);
    }

    function agcExecute(address oldAdmin) external {
        address newAdmin = adminCouncil.executeRecovery(adminCouncil.threshold);
        // Grant first…
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        // …then revoke the old one (safe-revoke sequence)
        if (oldAdmin != address(0) && hasRole(DEFAULT_ADMIN_ROLE, oldAdmin)) {
            _revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);
        }
    }

    function agcOwnerReset(address[] calldata newGuardians, uint8 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        adminCouncil.ownerResetGuardians(newGuardians, newThreshold);
    }

    function agcLastHonestReset(address[] calldata newGuardians, uint8 newThreshold) external {
        adminCouncil.lastHonestResetGuardians(msg.sender, newGuardians, newThreshold);
    }
}
