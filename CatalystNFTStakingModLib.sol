// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin upgradeable base contracts
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";

// Your libraries (keep them as libraries; ensure paths are correct)
import "./StakingLib.sol";
import "./GovernanceLib.sol";
import "./ConfigLib.sol";
import "./FeeLib.sol";
import "./TreasuryLib.sol";
import "./ProposalExecLib.sol";

/// @title CatalystNFTStakingUpgradeable
/// @notice UUPS-upgradeable version of Catalyst NFT staking. Uses libraries for modularity.
contract CatalystNFTStakingUpgradeable is
    ERC20Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IERC721ReceiverUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using StakingLib for StakingLib.Storage;
    using GovernanceLib for GovernanceLib.Storage;
    using ConfigLib for ConfigLib.Storage;
    using FeeLib for FeeLib.Storage;
    using TreasuryLib for TreasuryLib.Storage;

    // --- Roles ---
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // --- Storages from libs ---
    StakingLib.Storage internal s;
    GovernanceLib.Storage internal g;
    ConfigLib.Storage internal c;
    FeeLib.Storage internal f;
    TreasuryLib.Storage internal t;

    // Other top-level state
    address public deployerAddress;

    // Events (kept minimal)
    event NFTStaked(address indexed owner, address indexed collection, uint256 tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 tokenId);
    event RewardsHarvested(address indexed owner, uint256 amount, uint256 burned);
    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);
    event ProposalCreated(bytes32 indexed id, GovernanceLib.ProposalType pType, uint8 paramTarget, uint256 newValue, address collection, address proposer);
    event ProposalExecutedEvent(bytes32 indexed id, GovernanceLib.ProposalType pType, uint256 appliedValue);

    /// @notice Initialize (replaces constructor). Call once during deployment via the proxy.
    /// @param owner_ admin who will be DEFAULT_ADMIN_ROLE and CONTRACT_ADMIN_ROLE initially (can be replaced by timelock later)
    /// @param deployer_ deployer address that receives deployer fees
    /// @param mintAmount initial mint amount (example: 25_185_000 * 1e18)
    /// @param burnBP_ burn basis points (e.g., 9000)
    /// @param treasuryBP_ treasury basis points (e.g., 900)
    /// @param deployerBP_ deployer basis points (e.g., 100)
    /// @param govVotingDuration voting duration blocks initial
    /// @param govMinVotesScaled minVotesRequiredScaled initial
    /// @param govCollectionVoteCapPercent collection vote cap scaled
    function initialize(
        address owner_,
        address deployer_,
        uint256 mintAmount,
        uint16 burnBP_,
        uint16 treasuryBP_,
        uint16 deployerBP_,
        uint256 govVotingDuration,
        uint256 govMinVotesScaled,
        uint256 govCollectionVoteCapPercent
    ) public initializer {
        require(owner_ != address(0) && deployer_ != address(0), "bad addrs");

        // Initialize OZ upgradeable parents
        __ERC20_init("Catalyst", "CATA");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(CONTRACT_ADMIN_ROLE, owner_);

        // set deployer & mint initial supply to owner (same behavior as earlier)
        deployerAddress = deployer_;
        if (mintAmount > 0) {
            _mint(owner_, mintAmount);
        }

        // init fee library storage
        f.init(burnBP_, treasuryBP_, deployerBP_);

        // init governance lib
        GovernanceLib.initGov(g, govVotingDuration, govMinVotesScaled, govCollectionVoteCapPercent);

        // default small config values (you should call updateConfig later via admin or governance)
        // set a couple of safe defaults
        c.setUint(12, 18782); // numberOfBlocksPerRewardUnit (example)
    }

    // --- UUPS upgrade authorization ---
    /// @notice Only an account with DEFAULT_ADMIN_ROLE (recommended: Timelock address) can upgrade implementation.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // --- Example staking wrappers (call into StakingLib) ---
    function termStake(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        // perform the external transfer in main contract and call the library record function
        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakingLib.recordTermStake(
            s,
            collection,
            _msgSender(),
            tokenId,
            block.number,
            c.getUint(15) == 0 ? 0 : c.getUint(15), // termDurationBlocks paramId 15
            c.getUint(21) // rewardRateIncrementPerNFT paramId 21
        );

        uint256 dynamicWelcome = c.getUint(22) + (s.totalStakedNFTsCount * c.getUint(23));
        if (dynamicWelcome > 0) _mint(_msgSender(), dynamicWelcome);

        emit NFTStaked(_msgSender(), collection, tokenId);
    }

    function permanentStake(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        uint256 fee = c.getUint(19) + (_sqrt(s.totalStakedNFTsCount) * c.getUint(20)); // initialCollectionFee + sqrt * feeMultiplier
        require(balanceOf(_msgSender()) >= fee, "insufficient fee");

        IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

        // compute splits
        (uint256 burnAmt, uint256 treasuryAmt, uint256 deployerAmt) = f.computeSplits(fee);
        if (burnAmt > 0) _burn(_msgSender(), burnAmt);
        if (deployerAmt > 0) _transfer(_msgSender(), deployerAddress, deployerAmt);
        if (treasuryAmt > 0) { _transfer(_msgSender(), address(this), treasuryAmt); t.recordDeposit(_msgSender(), treasuryAmt); emit TreasuryDeposit(_msgSender(), treasuryAmt); }

        StakingLib.recordPermanentStake(
            s,
            collection,
            _msgSender(),
            tokenId,
            block.number,
            c.getUint(21) // rewardRateIncrementPerNFT
        );

        uint256 dynamicWelcome = c.getUint(22) + (s.totalStakedNFTsCount * c.getUint(23));
        if (dynamicWelcome > 0) _mint(_msgSender(), dynamicWelcome);

        emit NFTStaked(_msgSender(), collection, tokenId);
    }

    function unstake(address collection, uint256 tokenId) public nonReentrant whenNotPaused {
        StakingLib.StakeInfo memory info = s.stakeLog[collection][_msgSender()][tokenId];
        require(info.currentlyStaked, "not staked");
        if (!info.isPermanent) require(block.number >= info.unstakeDeadlineBlock, "term active");

        uint256 reward = StakingLib.pendingRewards(s, collection, _msgSender(), tokenId, c.getUint(12) == 0 ? 18782 : c.getUint(12));
        if (reward > 0) {
            uint256 feeRate = _getDynamicHarvestBurnFeeRate();
            uint256 burnAmt = (reward * feeRate) / 100;
            _mint(_msgSender(), reward);
            if (burnAmt > 0) {
                _burn(_msgSender(), burnAmt);
                // track burn stats if you want (keeps earlier variables if needed)
            }
            StakingLib.updateLastHarvest(s, collection, _msgSender(), tokenId);
            emit RewardsHarvested(_msgSender(), reward - burnAmt, burnAmt);
        }

        uint256 unstakeBurnFee = c.getUint(26);
        require(balanceOf(_msgSender()) >= unstakeBurnFee, "fee needed");

        (uint256 burnAmt2, uint256 treasuryAmt2, uint256 deployerAmt2) = f.computeSplits(unstakeBurnFee);
        if (burnAmt2 > 0) _burn(_msgSender(), burnAmt2);
        if (deployerAmt2 > 0) _transfer(_msgSender(), deployerAddress, deployerAmt2);
        if (treasuryAmt2 > 0) { _transfer(_msgSender(), address(this), treasuryAmt2); t.recordDeposit(_msgSender(), treasuryAmt2); emit TreasuryDeposit(_msgSender(), treasuryAmt2); }

        StakingLib.recordUnstake(s, collection, _msgSender(), tokenId, c.getUint(21));

        IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);

        emit NFTUnstaked(_msgSender(), collection, tokenId);
    }

    // --- Harvest single token ---
    function harvest(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        uint256 reward = StakingLib.pendingRewards(s, collection, _msgSender(), tokenId, c.getUint(12) == 0 ? 18782 : c.getUint(12));
        if (reward == 0) return;
        uint256 feeRate = _getDynamicHarvestBurnFeeRate();
        uint256 burnAmt = (reward * feeRate) / 100;
        _mint(_msgSender(), reward);
        if (burnAmt > 0) _burn(_msgSender(), burnAmt);
        StakingLib.updateLastHarvest(s, collection, _msgSender(), tokenId);
        emit RewardsHarvested(_msgSender(), reward - burnAmt, burnAmt);
    }

    // --- Governance wrappers (create, vote, execute) ---
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
        emit ProposalCreated(id, pType, paramTarget, newValue, collectionContext, _msgSender());
        return id;
    }

    function vote(bytes32 id) external whenNotPaused {
        (uint256 weight, address attributedCollection) = _votingWeight(_msgSender(), address(0));
        require(weight > 0, "not eligible");
        GovernanceLib.castVote(g, id, _msgSender(), weight, attributedCollection);
    }

    function executeProposal(bytes32 id) external whenNotPaused nonReentrant {
        GovernanceLib.Proposal memory p = GovernanceLib.validateForExecution(g, id);
        ProposalExecLib.applyProposal(g, s, c, id, p);
        GovernanceLib.markExecuted(g, id);
        emit ProposalExecutedEvent(id, p.pType, p.newValue);
    }

    // Voting weight same as before
    function _votingWeight(address voter, address /*context*/) internal view returns (uint256 weight, address attributedCollection) {
        for (uint256 i = 0; i < registeredCollections.length; i++) {
            address coll = registeredCollections[i];
            uint256[] storage port = s.stakePortfolioByUser[coll][voter];
            if (port.length == 0) continue;
            for (uint256 j = 0; j < port.length; j++) {
                StakingLib.StakeInfo storage si = s.stakeLog[coll][voter][port[j]];
                if (si.currentlyStaked && block.number >= si.stakeBlock + c.getUint(24)) {
                    return (StakingLib.WEIGHT_SCALE, coll);
                }
            }
        }
        return (0, address(0));
    }

    // --- Helpers & views ---
    function _getDynamicHarvestBurnFeeRate() public view returns (uint256) {
        uint256 initialRate = c.getUint(14);
        uint256 adjFactor = c.getUint(17);
        if (adjFactor == 0) return initialRate;
        // If you tracked burned amounts per user, use that; here we assume burnedCatalystByAddress mapping exists in s or separate tracking.
        // For simplicity, return initialRate (or implement per-user burn tracking).
        return initialRate;
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) { return StakingLib.sqrt(y); }

    // Expose minimal views
    function pendingRewardsView(address collection, address owner, uint256 tokenId) external view returns (uint256) {
        return StakingLib.pendingRewards(s, collection, owner, tokenId, c.getUint(12) == 0 ? 18782 : c.getUint(12));
    }

    function totalStakedNFTs() external view returns (uint256) { return s.totalStakedNFTsCount; }
    function baseReward() external view returns (uint256) { return s.baseRewardRate; }

    // --- Treasury helpers ---
    function withdrawTreasury(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant {
        t.recordWithdrawal(to, amount);
        _transfer(address(this), to, amount);
        emit TreasuryWithdrawal(to, amount);
    }

    function treasuryBalanceView() external view returns (uint256) {
        return t.balanceOf();
    }

    // --- ERC721 Receiver ---
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // --- Admin: pause/unpause ---
    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }

    // --- Keep arrays and mappings used earlier (registeredCollections etc) ---
    address[] public registeredCollections;
    mapping(address => uint256) public registeredIndex;

    // If you had burn-tracking / participants arrays in previous contract, re-add them here as storage variables
    mapping(address => uint256) public burnedCatalystByAddress;
    mapping(address => uint256) public lastBurnBlock;
    mapping(address => bool) public isParticipating;
    address[] public participatingWallets;

    mapping(address => uint256) public lastStakingBlock;
    uint256 public stakingCooldownBlocksBackup; // if needed

    // Note: If you had MAX_HARVEST_BATCH, MAX_STAKE_PER_COLLECTION, etc. as constants earlier,
    // they can stay as immutable constants in the implementation (they don't affect upgradeability if defined carefully).

    uint256 public constant WEIGHT_SCALE = 1e18;
    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public constant MAX_STAKE_PER_COLLECTION = 20000;

    // fallback variables you used previously (keep for compatibility)
    uint256 public treasuryBalance; // optional, we also use t.balance
    // ... (add any other state variables you previously used)

    // --- Storage-initialization caution ---
    // IMPORTANT: When you later upgrade, do NOT reorder or remove storage fields. Maintain layout compatibility.

}
