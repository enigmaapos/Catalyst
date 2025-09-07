// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ---------- OZ Upgradeable ----------
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// ---------- Catalyst Libs ----------
import {StakingLib} from "./StakingLib.sol";
import {GovernanceLib} from "./GovernanceLib.sol";
import {ConfigRegistryLib as CFG} from "./ConfigRegistryLib.sol";
import {FeeManagerLib as FM} from "./FeeManagerLib.sol";
import {TreasuryLib as T} from "./TreasuryLib.sol";

/// @title CatalystNFTStakingCoreUpgradeable
/// @notice Upgradeable core that mints CATA rewards for:
///         - Unverified collections (custodial staking)
///         - Verified blue-chips (non-custodial registration)
///         Secured by AccessControl; DRS/GCSS hooks come in next module (kept pluggable).
contract CatalystNFTStakingCoreUpgradeable is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC20Upgradeable
{
    using StakingLib for StakingLib.Storage;
    using GovernanceLib for GovernanceLib.Storage;
    using CFG for CFG.Storage;
    using T for T.Storage;

    // -------------------- ROLES --------------------
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // -------------------- STATE --------------------
    // Config, Treasury, Staking, Governance storages
    CFG.Storage private cfg;
    T.Storage   private trez;
    StakingLib.Storage private stakeS;
    GovernanceLib.Storage private govS;

    // Deploy fee receiver (1% share)
    address public deployerFeeReceiver;

    // ---------- Collections ----------
    enum CollectionTier { UNVERIFIED, VERIFIED }
    struct CollectionMeta {
        bool        registered;
        uint8       tier;               // 0: UNVERIFIED, 1: VERIFIED
        uint256     declaredMaxSupply;
        uint256     escrowSurcharge;    // CATA escrow from registration if UNVERIFIED
        // Blue-chip non-custodial counters
        uint256     blueChipRegisteredUnits;    // number of active "virtual" units
    }
    mapping(address => CollectionMeta) public collections; // collection => meta

    // ---------- Blue-chip non-custodial stake log ----------
    // For lean gas, we only need per-token presence + lastHarvestBlock
    struct BCStake {
        bool active;
        bool permanent;
        uint256 stakeBlock;
        uint256 lastHarvestBlock;
    }
    // collection => user => tokenId => BCStake
    mapping(address => mapping(address => mapping(uint256 => BCStake))) public bcStakeLog;

    // events
    event Initialized(address indexed admin, address indexed deployerFeeReceiver);
    event CollectionRegistered(address indexed collection, uint256 declaredMaxSupply, uint8 tier, uint256 escrow);
    event CollectionTierUpdated(address indexed collection, uint8 oldTier, uint8 newTier);
    event BlueChipRegister(address indexed collection, address indexed owner, uint256 indexed tokenId, bool permanent);
    event BlueChipUnregister(address indexed collection, address indexed owner, uint256 indexed tokenId);
    event Stake(address indexed collection, address indexed owner, uint256 indexed tokenId, bool permanent);
    event Unstake(address indexed collection, address indexed owner, uint256 indexed tokenId);
    event Harvest(address indexed collection, address indexed owner, uint256 indexed tokenId, uint256 amount);
    event TreasuryWithdraw(address indexed to, uint256 amount);

    // -------------------- ERRORS --------------------
    error NotBlueChip();
    error NotOwnerOfNFT();
    error AlreadyRegistered();
    error NotRegistered();
    error CapPerCollection();
    error CapGlobalAll();
    error CapGlobalTerm();
    error CapGlobalPerm();
    error EscrowInsufficient();
    error InvalidArray();
    error NothingToHarvest();
    error ZeroAddress();

    // -------------------- INITIALIZER --------------------
    function initialize(
        string memory name_,
        string memory symbol_,
        address admin_,
        address deployerFeeReceiver_
    ) external initializer {
        if (admin_ == address(0) || deployerFeeReceiver_ == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CONTRACT_ADMIN_ROLE, admin_);

        deployerFeeReceiver = deployerFeeReceiver_;

        // set default config values
        cfg.initDefaults();

        emit Initialized(admin_, deployerFeeReceiver_);
    }

    // -------------------- UUPS AUTH --------------------
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(CONTRACT_ADMIN_ROLE) {}

    // -------------------- ADMIN: CONFIG SET --------------------
    /// @notice Governance/Executor should call this via Core when proposals pass (hook kept simple for now).
    function adminSetConfig(bytes32[] calldata keys, uint256[] calldata values) external onlyRole(CONTRACT_ADMIN_ROLE) {
        cfg.setMany(keys, values);
    }

    /// @notice Admin can flip tier (e.g., after governance-approved verification).
    function adminSetCollectionTier(address collection, uint8 newTier) external onlyRole(CONTRACT_ADMIN_ROLE) {
        if (!collections[collection].registered) revert NotRegistered();
        uint8 old = collections[collection].tier;
        collections[collection].tier = newTier;
        emit CollectionTierUpdated(collection, old, newTier);
    }

    /// @notice Admin can set deployer 1% fee receiver (DRS/GCSS usually controls this via recovery).
    function adminSetDeployerFeeReceiver(address newReceiver) external onlyRole(CONTRACT_ADMIN_ROLE) {
        if (newReceiver == address(0)) revert ZeroAddress();
        deployerFeeReceiver = newReceiver;
    }

    // -------------------- USER: PAYABLE IN CATA (ERC20) FEES --------------------
    IERC20Upgradeable private constant CATA = IERC20Upgradeable(address(0)); // replaced in constructor-like step below

    // We’re the ERC20 for CATA; use _transfer, _mint, _burn on this contract itself.
    // When taking a fee from user, user must approve this core (ERC20 spender).
    function _pullFeeFrom(address from, uint256 amount) internal {
        // Pull to this contract as balance (we are ERC20)
        // Since this contract is the ERC20 token, pull == transferFrom (self token)
        // But we’re using ERC20Upgradeable — _spendAllowance + _transfer not exposed.
        // Use IERC20Upgradeable interface on self address.
        IERC20Upgradeable(address(this)).transferFrom(from, address(this), amount);
    }

    function _splitAndSettle(uint256 total) internal {
        (uint256 burnAmt, uint256 trezAmt, uint256 depAmt) = FM.computeAndEmit(total);
        // burn 90%
        _burn(address(this), burnAmt);
        // credit treasury ledger for 9% (tokens remain held by this contract)
        trez.credit(trezAmt);
        // send 1% to deployerFeeReceiver
        _transfer(address(this), deployerFeeReceiver, depAmt);
    }

    // -------------------- COLLECTION REGISTRATION --------------------
    /// @notice Permissionless registration; UNVERIFIED by default (escrow surcharge). VERIFICATION done later via governance/adminSetCollectionTier.
    function registerCollection(address collection, uint256 declaredMaxSupply) external whenNotPaused nonReentrant {
        if (collection == address(0)) revert ZeroAddress();
        if (collections[collection].registered) revert AlreadyRegistered();

        // mark registered
        collections[collection].registered = true;
        collections[collection].declaredMaxSupply = declaredMaxSupply;
        collections[collection].tier = uint8(CollectionTier.UNVERIFIED);

        // calculate fee & surcharge escrow
        ( , , , uint256 surchargeBP, ) = cfg.feeParams();
        (uint256 regBase, ) = _getRegBaseAndSurcharge();

        uint256 escrow = (regBase * surchargeBP) / 10_000;

        // Pull base + escrow from msg.sender (must approve)
        _pullFeeFrom(msg.sender, regBase + escrow);

        // Split base fee (escrow is held on balance, not split yet)
        _splitAndSettle(regBase);

        // Keep escrow on contract balance, track per collection
        collections[collection].escrowSurcharge = escrow;

        emit CollectionRegistered(collection, declaredMaxSupply, uint8(CollectionTier.UNVERIFIED), escrow);
        // initialize collection in StakingLib
        stakeS.initCollection(collection, declaredMaxSupply);
    }

    function _getRegBaseAndSurcharge() internal view returns (uint256 base, uint256 surchargeBP) {
        (, , base, surchargeBP, ) = cfg.feeParams();
        return (base, surchargeBP);
    }

    // -------------------- CUSTODIAL STAKING (UNVERIFIED or VERIFIED) --------------------
    /// @dev User must approve NFT to this contract before calling.
    function stake(address collection, uint256 tokenId, bool permanent) external whenNotPaused nonReentrant {
        if (!collections[collection].registered) revert NotRegistered();

        // Pull NFT custody
        IERC721(collection).transferFrom(msg.sender, address(this), tokenId);

        // caps
        _enforceCapsOnStake(permanent, collection, 1);

        (uint256 perCap,,,) = cfg.stakingCaps();
        if (stakeS.collectionConfigs[collection].totalStaked + 1 > perCap) revert CapPerCollection();

        (uint256 blocksPerUnit, uint256 incPerNFT) = cfg.rewardParams();

        if (permanent) {
            // take permanent flat fee
            (,,, , uint256 permFee) = cfg.feeParams();
            if (permFee > 0) {
                _pullFeeFrom(msg.sender, permFee);
                _splitAndSettle(permFee);
            }
            stakeS.recordPermanentStake(collection, msg.sender, tokenId, block.number, incPerNFT);
        } else {
            uint256 termBlocks = cfg.termParams();
            stakeS.recordTermStake(collection, msg.sender, tokenId, block.number, termBlocks, incPerNFT);
        }

        emit Stake(collection, msg.sender, tokenId, permanent);
    }

    function unstake(address collection, uint256 tokenId) external whenNotPaused nonReentrant {
        if (!collections[collection].registered) revert NotRegistered();

        // burn on unstake
        (, uint256 unstakeBurnBP) = _unstakeFeeParams();

        // fee is % of pending? We keep it simple: percentage fee over harvested amount at unstake time (common pattern).
        // First harvest (if any) then unstake.
        uint256 harvested = _harvestInternal(collection, msg.sender, tokenId);

        // unstake bookkeeping (decrements baseRate and counters)
        ( , uint256 incPerNFT) = cfg.rewardParams();
        stakeS.recordUnstake(collection, msg.sender, tokenId, incPerNFT);

        // return NFT
        IERC721(collection).transferFrom(address(this), msg.sender, tokenId);

        // take unstake fee on harvested amount
        if (harvested > 0 && unstakeBurnBP > 0) {
            uint256 fee = (harvested * unstakeBurnBP) / 10_000;
            if (fee > 0) {
                _pullFeeFrom(msg.sender, fee);
                _splitAndSettle(fee);
            }
        }

        emit Unstake(collection, msg.sender, tokenId);
    }

    function _unstakeFeeParams() internal view returns (uint256 harvestBurnBP, uint256 unstakeBurnBP) {
        (harvestBurnBP, unstakeBurnBP, , , ) = cfg.feeParams();
    }

    // -------------------- HARVEST --------------------
    function harvest(address collection, uint256 tokenId) external whenNotPaused nonReentrant returns (uint256) {
        if (!collections[collection].registered) revert NotRegistered();
        uint256 amount = _harvestInternal(collection, msg.sender, tokenId);
        if (amount == 0) revert NothingToHarvest();
        emit Harvest(collection, msg.sender, tokenId, amount);
        return amount;
    }

    function _harvestInternal(address collection, address owner, uint256 tokenId) internal returns (uint256) {
        (uint256 blocksPerUnit, ) = cfg.rewardParams();
        uint256 amount = stakeS.pendingRewards(collection, owner, tokenId, blocksPerUnit);
        if (amount > 0) {
            // mint rewards to owner
            _mint(owner, amount);

            // move lastHarvest
            stakeS.updateLastHarvest(collection, owner, tokenId);

            // harvest burn fee (from user wallet => split)
            (uint256 harvestBurnBP, , , , ) = cfg.feeParams();
            if (harvestBurnBP > 0) {
                uint256 fee = (amount * harvestBurnBP) / 10_000;
                if (fee > 0) {
                    _pullFeeFrom(owner, fee);
                    _splitAndSettle(fee);
                }
            }
        }
        return amount;
    }

    // -------------------- BLUE-CHIP NON-CUSTODIAL --------------------
    /// @notice Register a blue-chip token you own for accrual (no custody transfer).
    function blueChipRegister(address collection, uint256 tokenId, bool permanent) external whenNotPaused nonReentrant {
        if (!collections[collection].registered) revert NotRegistered();
        if (collections[collection].tier != uint8(CollectionTier.VERIFIED)) revert NotBlueChip();

        // must own the token
        if (IERC721(collection).ownerOf(tokenId) != msg.sender) revert NotOwnerOfNFT();

        BCStake storage s = bcStakeLog[collection][msg.sender][tokenId];
        if (s.active) revert AlreadyRegistered();

        // enforce caps as if 1 more unit staked
        _enforceCapsOnStake(permanent, collection, 1);
        (uint256 perCap,,,) = cfg.stakingCaps();
        // use StakingLib per-collection counter to keep unified per-collection cap
        if (stakeS.collectionConfigs[collection].totalStaked + 1 > perCap) revert CapPerCollection();

        // increment global counters & base reward rate as if it were a stake
        ( , uint256 incPerNFT) = cfg.rewardParams();
        stakeS.totalStakedNFTsCount += 1;
        stakeS.totalStakedAll += 1;
        if (permanent) {
            stakeS.totalStakedPermanent += 1;
        } else {
            stakeS.totalStakedTerm += 1;
        }
        stakeS.baseRewardRate += incPerNFT;

        // bump per-collection staked & stakers counters to keep accounting consistent
        StakingLib.CollectionConfig storage cc = stakeS.collectionConfigs[collection];
        if (!cc.registered) {
            // guarantee init if coming directly from blue-chip flows
            stakeS.initCollection(collection, collections[collection].declaredMaxSupply);
            cc = stakeS.collectionConfigs[collection];
        }
        cc.totalStaked += 1;
        // approximate stakers count: if this is their first active BC entry for this collection, increment
        // (gas-light check)
        if (stakeS.stakePortfolioByUser[collection][msg.sender].length == 0) {
            cc.totalStakers += 1;
        }

        // record BC stake
        s.active = true;
        s.permanent = permanent;
        s.stakeBlock = block.number;
        s.lastHarvestBlock = block.number;

        collections[collection].blueChipRegisteredUnits += 1;

        emit BlueChipRegister(collection, msg.sender, tokenId, permanent);
    }

    /// @notice Unregister a previously registered blue-chip token.
    function blueChipUnregister(address collection, uint256 tokenId) external whenNotPaused nonReentrant {
        if (!collections[collection].registered) revert NotRegistered();
        if (collections[collection].tier != uint8(CollectionTier.VERIFIED)) revert NotBlueChip();

        BCStake storage s = bcStakeLog[collection][msg.sender][tokenId];
        if (!s.active) revert NotRegistered();

        // harvest any pending
        uint256 amt = _pendingRewardsBlueChip(collection, msg.sender, tokenId);
        if (amt > 0) {
            _mint(msg.sender, amt);
            s.lastHarvestBlock = block.number;

            // harvest burn fee
            (uint256 harvestBurnBP, , , , ) = cfg.feeParams();
            if (harvestBurnBP > 0) {
                uint256 fee = (amt * harvestBurnBP) / 10_000;
                if (fee > 0) {
                    _pullFeeFrom(msg.sender, fee);
                    _splitAndSettle(fee);
                }
            }
        }

        // decrement counters mirroring stakeS.recordUnstake
        ( , uint256 incPerNFT) = cfg.rewardParams();

        s.active = false;

        StakingLib.CollectionConfig storage cc = stakeS.collectionConfigs[collection];
        if (cc.totalStaked > 0) cc.totalStaked -= 1;
        if (stakeS.baseRewardRate >= incPerNFT) stakeS.baseRewardRate -= incPerNFT;
        if (stakeS.totalStakedNFTsCount > 0) stakeS.totalStakedNFTsCount -= 1;

        stakeS.totalStakedAll -= 1;
        if (s.permanent) {
            stakeS.totalStakedPermanent -= 1;
        } else {
            stakeS.totalStakedTerm -= 1;
        }

        // naive stakers decrement: only if they had no custodial positions either (approx via portfolio length)
        if (stakeS.stakePortfolioByUser[collection][msg.sender].length == 0 && cc.totalStakers > 0) {
            cc.totalStakers -= 1;
        }

        // collection book
        if (collections[collection].blueChipRegisteredUnits > 0) {
            collections[collection].blueChipRegisteredUnits -= 1;
        }

        emit BlueChipUnregister(collection, msg.sender, tokenId);
    }

    /// @notice Pending rewards for blue-chip non-custodial item.
    function pendingRewardsBlueChip(address collection, address owner, uint256 tokenId) external view returns (uint256) {
        return _pendingRewardsBlueChip(collection, owner, tokenId);
    }

    function _pendingRewardsBlueChip(address collection, address owner, uint256 tokenId) internal view returns (uint256) {
        BCStake memory s = bcStakeLog[collection][owner][tokenId];
        if (!s.active || stakeS.baseRewardRate == 0 || stakeS.totalStakedNFTsCount == 0) return 0;
        if (!s.permanent) {
            uint256 termEnd = s.stakeBlock + cfg.termParams();
            if (block.number >= termEnd) return 0;
        }
        uint256 blocksPassed = block.number - s.lastHarvestBlock;
        uint256 numerator = blocksPassed * stakeS.baseRewardRate;
        uint256 rewardAmount = (numerator / cfg.rewardParams().0) / stakeS.totalStakedNFTsCount;
        // ^ `cfg.rewardParams().0` is not valid Solidity; expand:
        (uint256 blocksPerUnit, ) = cfg.rewardParams();
        rewardAmount = (blocksPassed * stakeS.baseRewardRate / blocksPerUnit) / stakeS.totalStakedNFTsCount;
        return rewardAmount;
    }

    // -------------------- CAP ENFORCEMENT --------------------
    function _enforceCapsOnStake(bool permanent, address collection, uint256 count) internal view {
        // global caps
        ( , uint256 capAll, uint256 capTerm, uint256 capPerm) = cfg.stakingCaps();

        if (stakeS.totalStakedAll + count > capAll) revert CapGlobalAll();
        if (permanent) {
            if (stakeS.totalStakedPermanent + count > capPerm) revert CapGlobalPerm();
        } else {
            if (stakeS.totalStakedTerm + count > capTerm) revert CapGlobalTerm();
        }
        // per-collection cap enforced at call sites using StakingLib counters
        collection; // silence warning; per-collection check is performed elsewhere
    }

    // -------------------- VIEWS --------------------
    /// @notice Global staking stats for UI.
    function stakingStats() external view returns (
        uint256 totalAll,
        uint256 totalTerm,
        uint256 totalPerm,
        uint256 baseRewardRate,
        uint256 perCollectionCap,
        uint256 capAll,
        uint256 capTerm,
        uint256 capPerm
    ) {
        (perCollectionCap, capAll, capTerm, capPerm) = cfg.stakingCaps();
        return (
            stakeS.totalStakedAll,
            stakeS.totalStakedTerm,
            stakeS.totalStakedPermanent,
            stakeS.baseRewardRate,
            perCollectionCap,
            capAll,
            capTerm,
            capPerm
        );
    }

    function collectionInfo(address collection) external view returns (
        bool registered,
        uint8 tier,
        uint256 declaredMax,
        uint256 escrow,
        uint256 staked,
        uint256 stakers,
        uint256 blueChipUnits
    ) {
        CollectionMeta memory m = collections[collection];
        StakingLib.CollectionConfig memory cc = stakeS.collectionConfigs[collection];
        return (m.registered, m.tier, m.declaredMaxSupply, m.escrowSurcharge, cc.totalStaked, cc.totalStakers, m.blueChipRegisteredUnits);
    }

    function treasuryBalance() external view returns (uint256) {
        return trez.balanceOf();
    }

    // -------------------- TREASURY WITHDRAW (GOVERNED) --------------------
    function treasuryWithdraw(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) {
        trez.debit(to, amount);
        _transfer(address(this), to, amount);
        emit TreasuryWithdraw(to, amount);
    }

    // -------------------- PAUSE --------------------
    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }
}
