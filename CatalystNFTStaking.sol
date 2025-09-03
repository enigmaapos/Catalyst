// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

/*
  Catalyst NFT Staking Protocol — Updated with safety & admin controls

  Key additions in this version:
  - Pausable: emergency pause/unpause (admin-only).
  - Admin management: add/remove CONTRACT_ADMIN_ROLE via DEFAULT_ADMIN_ROLE (so you can grant a multisig).
  - Rescue functions: emergencyWithdrawERC20 & rescueERC721 for stuck tokens.
  - Max base reward cap: setMaxBaseRewardRate to prevent runaway emissions.
  - Events for admin actions, pause, rescues.
  - Existing hardenings kept: safe harvest (mint then burn), admin-only setters, harvestBatch with MAX_HARVEST_BATCH, removeCollection.
  - Important recommendation: put DEFAULT_ADMIN_ROLE under a multisig (Gnosis Safe) and add a timelock in your governance flow.
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CatalystNFTStaking is ERC20, AccessControl, IERC721Receiver, ReentrancyGuard, Pausable {
    // Roles
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    // Structs
    struct CollectionConfig {
        uint256 totalStaked;
        uint256 totalStakers;
        bool registered;
    }

    struct StakeInfo {
        uint256 lastHarvestBlock;
        bool currentlyStaked;
        bool isPermanent;
        uint256 unstakeDeadlineBlock;
    }

    // Storage
    mapping(address => CollectionConfig) public collectionConfigs;
    mapping(address => mapping(uint256 => bool)) public welcomeBonusCollected;
    mapping(address => uint256) public lastStakingBlock;
    mapping(address => mapping(address => mapping(uint256 => StakeInfo))) public stakeLog;
    mapping(address => mapping(address => uint256[])) public stakePortfolioByUser;
    mapping(address => mapping(uint256 => uint256)) public indexOfTokenIdInStakePortfolio;
    mapping(address => uint256) public burnedCatalystByCollection;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => uint256) public votesForProposal;

    uint256 public numberOfBlocksPerRewardUnit;
    uint256 public collectionRegistrationFee;
    uint256 public unstakeBurnFee;
    address public treasuryAddress;
    uint256 public totalStakedNFTsCount;
    uint256 public baseRewardRate;
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

    address public immutable deployerAddress;
    uint256 public constant deployerFeeShareRate = 50;

    // Limits and caps
    uint256 public constant MAX_HARVEST_BATCH = 50;
    uint256 public maxBaseRewardRate; // admin-configurable cap

    // Events
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 payoutAmount, uint256 burnedAmount);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event CollectionAdded(address indexed collectionAddress);
    event CollectionRemoved(address indexed collectionAddress);
    event PermanentStakeFeePaid(address indexed staker, uint256 feeAmount);

    event BaseRewardRateUpdated(uint256 oldRate, uint256 newRate);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event EmergencyWithdrawnERC20(address token, address to, uint256 amount);
    event RescuedERC721(address token, uint256 tokenId, address to);
    event ProposalVoted(bytes32 indexed proposalId, address indexed voter);
    event ProposalExecuted(bytes32 indexed proposalId, uint256 newRate);

    constructor(
        address _owner,
        address _treasury,
        uint256 _initialCollectionFee,
        uint256 _feeMultiplier,
        uint256 _rewardRateIncrementPerNFT,
        uint256 _welcomeBonusBaseRate,
        uint256 _welcomeBonusIncrementPerNFT,
        uint256 _initialHarvestBurnFeeRate,
        uint256 _termDurationBlocks,
        uint256 _collectionRegistrationFee,
        uint256 _unstakeBurnFee,
        uint256 _stakingCooldownBlocks,
        uint256 _harvestRateAdjustmentFactor,
        uint256 _minBurnContributionForVote
    ) ERC20("Catalyst", "CATA") {
        require(_treasury != address(0), "CATA: Invalid treasury address");
        require(_owner != address(0), "CATA: Invalid owner");

        _mint(_owner, 25_185_000 * 10 ** 18);

        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        _setupRole(CONTRACT_ADMIN_ROLE, _owner);

        numberOfBlocksPerRewardUnit = 18782;
        treasuryAddress = _treasury;
        deployerAddress = _owner;

        initialCollectionFee = _initialCollectionFee;
        feeMultiplier = _feeMultiplier;
        rewardRateIncrementPerNFT = _rewardRateIncrementPerNFT;
        welcomeBonusBaseRate = _welcomeBonusBaseRate;
        welcomeBonusIncrementPerNFT = _welcomeBonusIncrementPerNFT;
        termDurationBlocks = _termDurationBlocks;
        stakingCooldownBlocks = _stakingCooldownBlocks;

        collectionRegistrationFee = _collectionRegistrationFee;
        unstakeBurnFee = _unstakeBurnFee;
        initialHarvestBurnFeeRate = _initialHarvestBurnFeeRate;
        harvestRateAdjustmentFactor = _harvestRateAdjustmentFactor;
        minBurnContributionForVote = _minBurnContributionForVote;
        baseRewardRate = 0;

        maxBaseRewardRate = type(uint256).max; // no cap by default; admin can set lower
    }

    // ---------- Modifiers ----------
    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: cooldown not passed");
        _;
    }

    modifier onlyAuthorizedVoter(address collectionAddress) {
        require(burnedCatalystByCollection[collectionAddress] >= minBurnContributionForVote, "CATA: not authorized voter");
        _;
    }

    // ---------- Governance ----------
    function proposeAndVote(uint256 newRate, address collectionAddress) external onlyAuthorizedVoter(collectionAddress) whenNotPaused {
        bytes32 proposalId = keccak256(abi.encodePacked("proposeBaseRewardRate", newRate));
        require(!hasVoted[proposalId][_msgSender()], "CATA: already voted");

        hasVoted[proposalId][_msgSender()] = true;
        votesForProposal[proposalId] += 1;
        emit ProposalVoted(proposalId, _msgSender());

        if (votesForProposal[proposalId] >= 2) {
            uint256 oldRate = baseRewardRate;
            // enforce cap
            if (maxBaseRewardRate != 0 && newRate > maxBaseRewardRate) {
                baseRewardRate = maxBaseRewardRate;
            } else {
                baseRewardRate = newRate;
            }
            emit ProposalExecuted(proposalId, baseRewardRate);
            emit BaseRewardRateUpdated(oldRate, baseRewardRate);
            delete votesForProposal[proposalId];
        }
    }

    // ---------- Math helpers ----------
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _getDynamicPermanentStakeFee() internal view returns (uint256) {
        return initialCollectionFee + (_sqrt(totalStakedNFTsCount) * feeMultiplier);
    }

    function _getDynamicHarvestBurnFeeRate() internal view returns (uint256) {
        if (harvestRateAdjustmentFactor == 0) return initialHarvestBurnFeeRate;
        uint256 rate = initialHarvestBurnFeeRate + (baseRewardRate / harvestRateAdjustmentFactor);
        if (rate > 90) return 90;
        return rate;
    }

    // ---------- Collection registration (admin allowlist) ----------
    function setCollectionConfig(address collectionAddress) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(collectionAddress != address(0), "CATA: Invalid address");
        require(!collectionConfigs[collectionAddress].registered, "CATA: already registered");

        uint256 fee = collectionRegistrationFee;
        require(balanceOf(_msgSender()) >= fee, "CATA: insufficient balance");

        uint256 burnAmount = (fee * 90) / 100;
        _burn(_msgSender(), burnAmount);

        burnedCatalystByCollection[collectionAddress] += burnAmount;

        uint256 treasuryAmount = fee - burnAmount;
        uint256 deployerShare = (treasuryAmount * deployerFeeShareRate) / 100;
        uint256 communityTreasuryShare = treasuryAmount - deployerShare;

        _transfer(_msgSender(), deployerAddress, deployerShare);
        _transfer(_msgSender(), treasuryAddress, communityTreasuryShare);

        collectionConfigs[collectionAddress] = CollectionConfig({ totalStaked: 0, totalStakers: 0, registered: true });

        emit CollectionAdded(collectionAddress);
    }

    function removeCollection(address collectionAddress) external onlyRole(CONTRACT_ADMIN_ROLE) whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: not registered");
        collectionConfigs[collectionAddress].registered = false;
        emit CollectionRemoved(collectionAddress);
    }

    // ---------- Staking ----------
    function termStake(address collectionAddress, uint256 tokenId) public nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: not registered");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        info.lastHarvestBlock = block.number;
        info.currentlyStaked = true;
        info.isPermanent = false;
        info.unstakeDeadlineBlock = block.number + termDurationBlocks;

        CollectionConfig storage config = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][_msgSender()].length == 0) {
            config.totalStakers += 1;
        }
        config.totalStaked += 1;

        totalStakedNFTsCount += 1;
        baseRewardRate += rewardRateIncrementPerNFT;

        stakePortfolioByUser[collectionAddress][_msgSender()].push(tokenId);
        indexOfTokenIdInStakePortfolio[collectionAddress][tokenId] = stakePortfolioByUser[collectionAddress][_msgSender()].length - 1;

        if (!welcomeBonusCollected[collectionAddress][tokenId]) {
            uint256 dynamicWelcomeBonus = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
            _mint(_msgSender(), dynamicWelcomeBonus);
            welcomeBonusCollected[collectionAddress][tokenId] = true;
        }

        lastStakingBlock[_msgSender()] = block.number;
        emit NFTStaked(_msgSender(), collectionAddress, tokenId);
    }

    function permanentStake(address collectionAddress, uint256 tokenId) public nonReentrant notInCooldown whenNotPaused {
        require(collectionConfigs[collectionAddress].registered, "CATA: not registered");

        uint256 currentFee = _getDynamicPermanentStakeFee();
        require(balanceOf(_msgSender()) >= currentFee, "CATA: insufficient balance");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);

        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: already staked");

        uint256 burnAmount = (currentFee * 90) / 100;
        _burn(_msgSender(), burnAmount);
        burnedCatalystByCollection[collectionAddress] += burnAmount;

        uint256 treasuryAmount = currentFee - burnAmount;
        uint256 deployerShare = (treasuryAmount * deployerFeeShareRate) / 100;
        uint256 communityTreasuryShare = treasuryAmount - deployerShare;

        _transfer(_msgSender(), deployerAddress, deployerShare);
        _transfer(_msgSender(), treasuryAddress, communityTreasuryShare);

        info.lastHarvestBlock = block.number;
        info.currentlyStaked = true;
        info.isPermanent = true;
        info.unstakeDeadlineBlock = 0;

        CollectionConfig storage config = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][_msgSender()].length == 0) {
            config.totalStakers += 1;
        }
        config.totalStaked += 1;

        totalStakedNFTsCount += 1;
        baseRewardRate += rewardRateIncrementPerNFT;

        stakePortfolioByUser[collectionAddress][_msgSender()].push(tokenId);
        indexOfTokenIdInStakePortfolio[collectionAddress][tokenId] = stakePortfolioByUser[collectionAddress][_msgSender()].length - 1;

        if (!welcomeBonusCollected[collectionAddress][tokenId]) {
            uint256 dynamicWelcomeBonus = welcomeBonusBaseRate + (totalStakedNFTsCount * welcomeBonusIncrementPerNFT);
            _mint(_msgSender(), dynamicWelcomeBonus);
            welcomeBonusCollected[collectionAddress][tokenId] = true;
        }

        lastStakingBlock[_msgSender()] = block.number;
        emit PermanentStakeFeePaid(_msgSender(), currentFee);
        emit NFTStaked(_msgSender(), collectionAddress, tokenId);
    }

    // ---------- Unstake ----------
    function unstake(address collectionAddress, uint256 tokenId) public nonReentrant whenNotPaused {
        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(info.currentlyStaked, "CATA: not staked");

        if (!info.isPermanent) {
            require(block.number >= info.unstakeDeadlineBlock, "CATA: term not expired");
        }

        _harvest(collectionAddress, _msgSender(), tokenId);

        require(balanceOf(_msgSender()) >= unstakeBurnFee, "CATA: insufficient for unstake fee");
        _burn(_msgSender(), unstakeBurnFee);

        info.currentlyStaked = false;

        uint256[] storage portfolio = stakePortfolioByUser[collectionAddress][_msgSender()];
        uint256 indexToRemove = indexOfTokenIdInStakePortfolio[collectionAddress][tokenId];
        uint256 lastIndex = portfolio.length - 1;

        if (indexToRemove != lastIndex) {
            uint256 lastTokenId = portfolio[lastIndex];
            portfolio[indexToRemove] = lastTokenId;
            indexOfTokenIdInStakePortfolio[collectionAddress][lastTokenId] = indexToRemove;
        }

        portfolio.pop();
        delete indexOfTokenIdInStakePortfolio[collectionAddress][tokenId];

        IERC721(collectionAddress).safeTransferFrom(address(this), _msgSender(), tokenId);

        CollectionConfig storage config = collectionConfigs[collectionAddress];
        if (stakePortfolioByUser[collectionAddress][_msgSender()].length == 0) {
            config.totalStakers -= 1;
        }
        config.totalStaked -= 1;

        if (baseRewardRate >= rewardRateIncrementPerNFT) {
            baseRewardRate -= rewardRateIncrementPerNFT;
        }

        emit NFTUnstaked(_msgSender(), collectionAddress, tokenId);
    }

    // ---------- Harvest (safe) ----------
    function _harvest(address collectionAddress, address user, uint256 tokenId) internal {
        StakeInfo storage info = stakeLog[collectionAddress][user][tokenId];
        uint256 rewardAmount = pendingRewards(collectionAddress, user, tokenId);

        if (rewardAmount > 0) {
            uint256 dynamicHarvestBurnFeeRate = _getDynamicHarvestBurnFeeRate();
            uint256 burnAmount = (rewardAmount * dynamicHarvestBurnFeeRate) / 100;
            uint256 payoutAmount = rewardAmount - burnAmount;

            _mint(user, rewardAmount);

            if (burnAmount > 0) {
                _burn(user, burnAmount);
                burnedCatalystByCollection[collectionAddress] += burnAmount;
            }

            info.lastHarvestBlock = block.number;
            emit RewardsHarvested(user, collectionAddress, payoutAmount, burnAmount);
        }
    }

    function harvestBatch(address collectionAddress, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0, "CATA: no tokenIds");
        require(tokenIds.length <= MAX_HARVEST_BATCH, "CATA: batch too large");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            _harvest(collectionAddress, _msgSender(), tokenIds[i]);
        }
    }

    // ---------- Pending rewards ----------
    function pendingRewards(address collectionAddress, address owner, uint256 tokenId) public view returns (uint256) {
        StakeInfo memory info = stakeLog[collectionAddress][owner][tokenId];
        if (!info.currentlyStaked || baseRewardRate == 0 || totalStakedNFTsCount == 0) return 0;
        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) return 0;

        uint256 blocksPassed = block.number - info.lastHarvestBlock;
        uint256 numerator = blocksPassed * baseRewardRate;
        uint256 rewardAmount = (numerator / numberOfBlocksPerRewardUnit) / totalStakedNFTsCount;
        return rewardAmount;
    }

    // ---------- Admin setters (restricted) ----------
    function setBaseRewardRate(uint256 _newRate) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(maxBaseRewardRate == 0 || _newRate <= maxBaseRewardRate, "CATA: exceeds max cap");
        uint256 old = baseRewardRate;
        baseRewardRate = _newRate;
        emit BaseRewardRateUpdated(old, _newRate);
    }

    function setMaxBaseRewardRate(uint256 _cap) external onlyRole(CONTRACT_ADMIN_ROLE) {
        maxBaseRewardRate = _cap;
    }

    function setWelcomeBonusBaseRate(uint256 _newRate) external onlyRole(CONTRACT_ADMIN_ROLE) {
        uint256 old = welcomeBonusBaseRate;
        welcomeBonusBaseRate = _newRate;
        emit BaseRewardRateUpdated(old, _newRate);
    }

    function setWelcomeBonusIncrementPerNFT(uint256 _increment) external onlyRole(CONTRACT_ADMIN_ROLE) {
        welcomeBonusIncrementPerNFT = _increment;
    }

    function setHarvestBurnFeeRate(uint256 _rate) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_rate <= 100, "CATA: rate > 100");
        initialHarvestBurnFeeRate = _rate;
    }

    function setHarvestRateAdjustmentFactor(uint256 _factor) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(_factor > 0, "CATA: >0");
        harvestRateAdjustmentFactor = _factor;
    }

    function setTermDurationBlocks(uint256 _blocks) external onlyRole(CONTRACT_ADMIN_ROLE) {
        termDurationBlocks = _blocks;
    }

    function setUnstakeBurnFee(uint256 _fee) external onlyRole(CONTRACT_ADMIN_ROLE) {
        unstakeBurnFee = _fee;
    }

    function setStakingCooldownBlocks(uint256 _blocks) external onlyRole(CONTRACT_ADMIN_ROLE) {
        stakingCooldownBlocks = _blocks;
    }

    function setMinBurnContributionForVote(uint256 _min) external onlyRole(CONTRACT_ADMIN_ROLE) {
        minBurnContributionForVote = _min;
    }

    // ---------- Pausable (emergency) ----------
    function pause() external onlyRole(CONTRACT_ADMIN_ROLE) {
        _pause();
        emit Paused(_msgSender());
    }

    function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) {
        _unpause();
        emit Unpaused(_msgSender());
    }

    // ---------- Admin management (use DEFAULT_ADMIN_ROLE to grant/remove) ----------
    function addContractAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(CONTRACT_ADMIN_ROLE, admin);
        emit AdminAdded(admin);
    }

    function removeContractAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(CONTRACT_ADMIN_ROLE, admin);
        emit AdminRemoved(admin);
    }

    // ---------- Rescue utilities (admin-only) ----------
    function emergencyWithdrawERC20(address token, address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(to != address(0), "CATA: invalid to");
        IERC20(token).transfer(to, amount);
        emit EmergencyWithdrawnERC20(token, to, amount);
    }

    function rescueERC721(address token, uint256 tokenId, address to) external onlyRole(CONTRACT_ADMIN_ROLE) {
        require(to != address(0), "CATA: invalid to");
        IERC721(token).safeTransferFrom(address(this), to, tokenId);
        emit RescuedERC721(token, tokenId, to);
    }

    // ---------- Getters ----------
    function getDynamicPermanentStakeFee() public view returns (uint256) {
        return _getDynamicPermanentStakeFee();
    }

    function getDynamicHarvestBurnFeeRate() public view returns (uint256) {
        return _getDynamicHarvestBurnFeeRate();
    }

    function getLastStakingBlock(address user) public view returns (uint256) {
        return lastStakingBlock[user];
    }

    function getBurnedCatalystByCollection(address collectionAddress) public view returns (uint256) {
        return burnedCatalystByCollection[collectionAddress];
    }

    // ---------- ERC721 Receiver ----------
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
