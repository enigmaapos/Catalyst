// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ==== OpenZeppelin Upgradeable ====
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// ==== Internal Modular Libs ====
import "./StakingLib.sol";
import "./GovernanceLib.sol";
import "./ConfigLib.sol";
import "./FeeLib.sol";
import "./TreasuryLib.sol";
import "./ProposalExecLib.sol";

/// @title Catalyst NFT Staking Protocol (Upgradeable)
/// @notice ERC20 with NFT staking, governance, treasury, and upgradability
contract CatalystNFTStakingUpgradeable is
    ERC20Upgradeable,
    AccessControlUpgradeable,
    IERC721ReceiverUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using StakingLib for StakingLib.Storage;
    using GovernanceLib for GovernanceLib.Storage;
    using ConfigLib for ConfigLib.Storage;
    using FeeLib for FeeLib.Storage;
    using TreasuryLib for TreasuryLib.Storage;

    // === Roles ===
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // === Storage ===
    StakingLib.Storage internal s;
    GovernanceLib.Storage internal g;
    ConfigLib.Storage internal c;
    FeeLib.Storage internal f;
    TreasuryLib.Storage internal t;

    address public deployer;

    // === Events ===
    event NFTStaked(address indexed staker, address indexed collection, uint256 tokenId);
    event NFTUnstaked(address indexed staker, address indexed collection, uint256 tokenId);
    event RewardHarvested(address indexed staker, uint256 amount);
    event ProposalCreated(bytes32 indexed id, GovernanceLib.ProposalType pType, uint256 newValue);
    event ProposalExecuted(bytes32 indexed id);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // lock implementation
    }

    /// @notice Initialize function (replaces constructor for upgradeable contracts)
    function initialize(
        address admin_,
        address deployer_,
        uint256 initialSupply,
        uint16 burnBP_,
        uint16 treasuryBP_,
        uint16 deployerBP_,
        uint256 votingDurationBlocks,
        uint256 minVotes,
        uint256 collectionVoteCap
    ) external initializer {
        __ERC20_init("Catalyst Token", "CAT");
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        require(admin_ != address(0), "Catalyst: admin zero");
        require(deployer_ != address(0), "Catalyst: deployer zero");

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CONTRACT_ADMIN_ROLE, admin_);

        deployer = deployer_;

        // Mint supply to deployer
        _mint(deployer_, initialSupply);

        // Init fee splits
        f.init(burnBP_, treasuryBP_, deployerBP_);

        // Init governance parameters
        g.init(votingDurationBlocks, minVotes, collectionVoteCap);
    }

    // === Staking ===
    function stakeNFT(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
        s.stakeNFT(_msgSender(), collection, tokenId, address(this));
        emit NFTStaked(_msgSender(), collection, tokenId);
    }

    function unstakeNFT(address collection, uint256 tokenId) external nonReentrant {
        s.unstakeNFT(_msgSender(), collection, tokenId, address(this));
        emit NFTUnstaked(_msgSender(), collection, tokenId);
    }

    // === Rewards ===
    function harvestRewards() external nonReentrant {
        uint256 reward = s.harvestRewards(_msgSender(), address(this));
        emit RewardHarvested(_msgSender(), reward);
    }

    // === Governance ===
    function createProposal(GovernanceLib.Proposal memory p) external whenNotPaused {
        bytes32 id = g.createProposal(_msgSender(), p);
        emit ProposalCreated(id, p.pType, p.newValue);
    }

    function vote(bytes32 proposalId, bool support) external whenNotPaused {
        g.vote(_msgSender(), proposalId, support, s);
    }

    function executeProposal(bytes32 proposalId) external whenNotPaused {
        GovernanceLib.Proposal memory p = GovernanceLib.validateForExecution(g, proposalId);
        ProposalExecLib.applyProposal(g, s, c, proposalId, p);
        g.markExecuted(proposalId);
        emit ProposalExecuted(proposalId);
    }

    // === Config Management ===
    function updateConfig(uint8 paramId, uint256 newValue) external onlyRole(CONTRACT_ADMIN_ROLE) {
        c.setUint(paramId, newValue);
    }

    function getConfig(uint8 paramId) external view returns (uint256) {
        return c.getUint(paramId);
    }

    // === Fee Handling ===
    function handleFeeFromSender(address from, uint256 amount) external nonReentrant {
        (uint256 burnAmt, uint256 treasuryAmt, uint256 deployerAmt) = f.computeSplits(amount);
        if (burnAmt > 0) _burn(from, burnAmt);
        if (treasuryAmt > 0) {
            _transfer(from, address(this), treasuryAmt);
            t.recordDeposit(from, treasuryAmt);
        }
        if (deployerAmt > 0) _transfer(from, deployer, deployerAmt);
    }

    // === Treasury ===
    function treasuryBalance() external view returns (uint256) {
        return t.balanceOf();
    }

    function withdrawTreasury(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) {
        t.recordWithdrawal(to, amount);
        _transfer(address(this), to, amount);
    }

    // === ERC721 Receiver ===
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // === Admin ===
    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) {
        _unpause();
    }

    // === UUPS Authorization ===
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
