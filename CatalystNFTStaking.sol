
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title Catalyst NFT Staking Protocol
 * @author Var
 * @dev NFT staking protocol with dynamic rewards, deflationary token mechanics,
 * and simple governance by collections. Collections are added via admin allowlist.
 */
contract CatalystNFTStaking is ERC20, AccessControl, IERC721Receiver, ReentrancyGuard {
    // Roles
    bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

    struct CollectionConfig {
        uint256 totalStaked;
        uint256 totalStakers;
        bool registered;
    }

    mapping(address => CollectionConfig) public collectionConfigs;
    mapping(address => mapping(uint256 => bool)) public welcomeBonusCollected;
    mapping(address => uint256) public lastStakingBlock;

    struct StakeInfo {
        uint256 lastHarvestBlock;
        bool currentlyStaked;
        bool isPermanent;
        uint256 unstakeDeadlineBlock;
    }

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

    // Events
    event RewardsHarvested(address indexed owner, address indexed collection, uint256 amount, uint256 burnedAmount);
    event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
    event CollectionAdded(address indexed collectionAddress);
    event PermanentStakeFeePaid(address indexed staker, uint256 feeAmount);

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
        _mint(_owner, 25_185_000 * 10 ** 18);
        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        _setupRole(CONTRACT_ADMIN_ROLE, _owner);

        numberOfBlocksPerRewardUnit = 18782; // ~1 day on Polygon
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
    }

    modifier notInCooldown() {
        require(block.number >= lastStakingBlock[_msgSender()] + stakingCooldownBlocks, "CATA: Staking cooldown not passed");
        _;
    }

    modifier onlyAuthorizedVoter(address collectionAddress) {
        require(burnedCatalystByCollection[collectionAddress] >= minBurnContributionForVote, "CATA: Not authorized voter");
        _;
    }

    // Governance
    function proposeAndVote(uint256 newRate, address collectionAddress) external onlyAuthorizedVoter(collectionAddress) {
        bytes32 proposalId = keccak256(abi.encodePacked("proposeBaseRewardRate", newRate));
        require(!hasVoted[proposalId][_msgSender()], "CATA: Already voted");

        hasVoted[proposalId][_msgSender()] = true;
        votesForProposal[proposalId] += 1;

        if (votesForProposal[proposalId] >= 2) {
            baseRewardRate = newRate;
            delete votesForProposal[proposalId];
        }
    }

    // Math
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
        return rate > 90 ? 90 : rate;
    }

    // Admin allowlist for NFT collections
    function setCollectionConfig(address collectionAddress) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant {
        require(collectionAddress != address(0), "CATA: Invalid address");
        require(!collectionConfigs[collectionAddress].registered, "CATA: Already registered");

        uint256 fee = collectionRegistrationFee;
        require(balanceOf(_msgSender()) >= fee, "CATA: Insufficient CATA for fee");

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

    // Staking
    function termStake(address collectionAddress, uint256 tokenId) public nonReentrant notInCooldown {
        require(collectionConfigs[collectionAddress].registered, "CATA: Collection not registered");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);
        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: Already staked");

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

    function permanentStake(address collectionAddress, uint256 tokenId) public nonReentrant notInCooldown {
        require(collectionConfigs[collectionAddress].registered, "CATA: Collection not registered");

        uint256 currentFee = _getDynamicPermanentStakeFee();
        require(balanceOf(_msgSender()) >= currentFee, "CATA: Insufficient CATA balance");

        IERC721(collectionAddress).safeTransferFrom(_msgSender(), address(this), tokenId);
        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(!info.currentlyStaked, "CATA: Already staked");

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

    function unstake(address collectionAddress, uint256 tokenId) public nonReentrant {
        StakeInfo storage info = stakeLog[collectionAddress][_msgSender()][tokenId];
        require(info.currentlyStaked, "CATA: Not staked");

        if (!info.isPermanent) {
            require(block.number >= info.unstakeDeadlineBlock, "CATA: Term not expired");
        }

        _harvest(collectionAddress, _msgSender(), tokenId);

        require(balanceOf(_msgSender()) >= unstakeBurnFee, "CATA: Insufficient CATA for unstake fee");
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

    function _harvest(address collectionAddress, address user, uint256 tokenId) internal {
        StakeInfo storage info = stakeLog[collectionAddress][user][tokenId];
        uint256 rewardAmount = pendingRewards(collectionAddress, user, tokenId);

        if (rewardAmount > 0) {
            uint256 dynamicHarvestBurnFeeRate = _getDynamicHarvestBurnFeeRate();
            uint256 burnAmount = (rewardAmount * dynamicHarvestBurnFeeRate) / 100;
            uint256 payoutAmount = rewardAmount - burnAmount;

            _burn(address(this), burnAmount);
            burnedCatalystByCollection[collectionAddress] += burnAmount;

            _mint(user, payoutAmount);
            info.lastHarvestBlock = block.number;

            emit RewardsHarvested(user, collectionAddress, payoutAmount, burnAmount);
        }
    }

    function harvestAll(address collectionAddress) public nonReentrant {
        uint256[] memory stakedTokens = stakePortfolioByUser[collectionAddress][_msgSender()];
        for (uint256 i = 0; i < stakedTokens.length; i++) {
            _harvest(collectionAddress, _msgSender(), stakedTokens[i]);
        }
    }

    function pendingRewards(address collectionAddress, address owner, uint256 tokenId) public view returns (uint256) {
        StakeInfo memory info = stakeLog[collectionAddress][owner][tokenId];
        if (!info.currentlyStaked || baseRewardRate == 0 || totalStakedNFTsCount == 0) return 0;

        if (!info.isPermanent && block.number >= info.unstakeDeadlineBlock) return 0;

        uint256 blocksPassed = block.number - info.lastHarvestBlock;
        uint256 rewardPerUnit = (baseRewardRate * (10 ** 18)) / totalStakedNFTsCount;
        uint256 rewardAmount = (blocksPassed / numberOfBlocksPerRewardUnit) * rewardPerUnit;
        return rewardAmount;
    }

    // Admin setters
    function setBaseRewardRate(uint256 _newRate) external { baseRewardRate = _newRate; }
    function setWelcomeBonusBaseRate(uint256 _newRate) external { welcomeBonusBaseRate = _newRate; }
    function setWelcomeBonusIncrementPerNFT(uint256 _increment) external { welcomeBonusIncrementPerNFT = _increment; }
    function setHarvestBurnFeeRate(uint256 _rate) external { require(_rate <= 100, "CATA: >100"); initialHarvestBurnFeeRate = _rate; }
    function setHarvestRateAdjustmentFactor(uint256 _factor) external { require(_factor > 0, "CATA: >0"); harvestRateAdjustmentFactor = _factor; }
    function setTermDurationBlocks(uint256 _blocks) external { termDurationBlocks = _blocks; }
    function setUnstakeBurnFee(uint256 _fee) external { unstakeBurnFee = _fee; }
    function setStakingCooldownBlocks(uint256 _blocks) external { stakingCooldownBlocks = _blocks; }
    function setMinBurnContributionForVote(uint256 _min) external onlyRole(CONTRACT_ADMIN_ROLE) { minBurnContributionForVote = _min; }

    // Getters
    function getDynamicPermanentStakeFee() public view returns (uint256) { return _getDynamicPermanentStakeFee(); }
    function getDynamicHarvestBurnFeeRate() public view returns (uint256) { return _getDynamicHarvestBurnFeeRate(); }
    function getLastStakingBlock(address user) public view returns (uint256) { return lastStakingBlock[user]; }
    function getBurnedCatalystByCollection(address collectionAddress) public view returns (uint256) { return burnedCatalystByCollection[collectionAddress]; }

    // ERC721 Receiver
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
