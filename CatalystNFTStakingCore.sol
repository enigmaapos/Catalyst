// SPDX-License-Identifier: MIT
 pragma solidity ^0.8.20;

 import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
 import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
 import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
 import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
 import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
 import "@openzeppelin/contracts/security/Pausable.sol";
 import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
 import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
 import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

 import "./StakingLib.sol";
 import "./GovernanceLib.sol";
 import "./ConfigRegistryLib.sol";
 import "./FeeManagerLib.sol";
 import "./ProposalExecutorLib.sol";
 import "./TreasuryLib.sol";

 contract CatalystNFTStakingCore is
     Initializable,
     ERC20Upgradeable,
     AccessControlUpgradeable,
     UUPSUpgradeable,
     ReentrancyGuard,
     Pausable,
     IERC721Receiver
 {
     using StakingLib for StakingLib.Storage;
     using GovernanceLib for GovernanceLib.Storage;
     using ConfigRegistryLib for ConfigRegistryLib.ConfigStorage;
     using FeeManagerLib for FeeManagerLib.FeeState;
     using ProposalExecutorLib for ProposalExecutorLib.ExecContext;
     using TreasuryLib for TreasuryLib.TreasuryState;

     // roles
     bytes32 public constant CONTRACT_ADMIN_ROLE = keccak256("CONTRACT_ADMIN_ROLE");

     // Storage objects (passable to libs)
     StakingLib.Storage internal staking;
     GovernanceLib.Storage internal governance;
     ConfigRegistryLib.ConfigStorage internal config;
     FeeManagerLib.FeeState internal feeState;
     TreasuryLib.TreasuryState internal treasury;

     // Immutable-ish deployer saved in initialize
     address public deployerAddress;

     // Events (subset)
     event NFTStaked(address indexed owner, address indexed collection, uint256 indexed tokenId, bool permanent);
     event NFTUnstaked(address indexed owner, address indexed collection, uint256 indexed tokenId);
     event RewardsHarvested(address indexed owner, address indexed collection, uint256 payoutAmount, uint256 burnedAmount);
     event CollectionAdded(address indexed collection, uint256 declaredSupply, uint256 baseFee, uint256 surchargeEscrow, ConfigRegistryLib.CollectionTier tier);
     event ProposalCreated(bytes32 indexed id, GovernanceLib.ProposalType pType, uint8 paramTarget, address indexed collection, address indexed proposer, uint256 newValue, uint256 startBlock, uint256 endBlock);
     event VoteCast(bytes32 indexed id, address indexed voter, uint256 weightScaled, address attributedCollection);
     event ProposalExecuted(bytes32 indexed id, uint256 appliedValue);

     // initializer (replace constructor)
     struct InitConfig {
         address owner;
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
     }

     function initialize(InitConfig calldata cfg) public initializer {
         require(cfg.owner != address(0), "bad owner");
         __ERC20_init("Catalyst", "CATA");
         __AccessControl_init();
         __UUPSUpgradeable_init();

         // initial mint to owner (same as merged)
         _mint(cfg.owner, 25_185_000 * 10**18);

         _grantRole(DEFAULT_ADMIN_ROLE, cfg.owner);
         _grantRole(CONTRACT_ADMIN_ROLE, cfg.owner);

         deployerAddress = cfg.owner;

         // ConfigRegistry defaults
         config.initialCollectionFee = cfg.initialCollectionFee;
         config.feeMultiplier = cfg.feeMultiplier;
         config.rewardRateIncrementPerNFT = cfg.rewardRateIncrementPerNFT;
         config.welcomeBonusBaseRate = cfg.welcomeBonusBaseRate;
         config.welcomeBonusIncrementPerNFT = cfg.welcomeBonusIncrementPerNFT;
         config.initialHarvestBurnFeeRate = cfg.initialHarvestBurnFeeRate;
         config.termDurationBlocks = cfg.termDurationBlocks;
         config.collectionRegistrationFee = cfg.collectionRegistrationFeeFallback;
         config.unstakeBurnFee = cfg.unstakeBurnFee;
         config.stakingCooldownBlocks = cfg.stakingCooldownBlocks;
         config.harvestRateAdjustmentFactor = cfg.harvestRateAdjustmentFactor;
         config.minBurnContributionForVote = cfg.minBurnContributionForVote;

         // Fee manager initial state
         feeState.deployer = deployerAddress;
         feeState.treasuryBalance = 0;

         // Treasury: keep funds inside contract's ERC20 balance; track via treasury.balance
         treasury.balance = 0;

         // governance default values
         governance.votingDurationBlocks = 46000;
         governance.minVotesRequiredScaled = 3 * StakingLib.WEIGHT_SCALE;
         governance.smallCollectionVoteWeightScaled = (StakingLib.WEIGHT_SCALE * 50) / 100;
         governance.collectionVoteCapPercent = 70;
         governance.minStakeAgeForVoting = 100;

         // registration fee bracket defaults (copied from merged contract)
         config.SMALL_MIN_FEE = 1000 * 10**18;
         config.SMALL_MAX_FEE = 5000 * 10**18;
         config.MED_MIN_FEE = 5000 * 10**18;
         config.MED_MAX_FEE = 10000 * 10**18;
         config.LARGE_MIN_FEE = 10000 * 10**18;
         config.LARGE_MAX_FEE_CAP = 20000 * 10**18;
         config.unverifiedSurchargeBP = 20000; // 2x by default

         // other defaults kept minimal; libraries expose setters as admin functions
     }

     // --------------------
     // PUBLIC / USER-FACING
     // --------------------

     // stake (term or permanent)
     function stake(address collection, uint256 tokenId, bool permanent) external nonReentrant whenNotPaused {
         require(collection != address(0), "bad collection");
         // transfer NFT to contract first (will revert if not approved)
         IERC721(collection).safeTransferFrom(_msgSender(), address(this), tokenId);

         // delegate to staking lib to update bookkeeping
         if (permanent) {
             // compute fee that must be collected on permanent stake
             uint256 fee = config.getDynamicPermanentStakeFee(staking.totalStakedNFTsCount);
             // require user has enough tokens; core will process split
             require(balanceOf(_msgSender()) >= fee, "insufficient CATA for fee");
             // collect fee via immutable split
             _splitFeeFromSender(_msgSender(), fee, collection, true);
             staking._recordPermanentStake(collection, _msgSender(), tokenId, config);
             emit NFTStaked(_msgSender(), collection, tokenId, true);
         } else {
             staking._recordTermStake(collection, _msgSender(), tokenId, config);
             emit NFTStaked(_msgSender(), collection, tokenId, false);
         }
     }

     // batch wrappers
     function batchStake(address collection, uint256[] calldata tokenIds, bool permanent) external {
         require(tokenIds.length > 0 && tokenIds.length <= StakingLib.MAX_BATCH, "bad batch");
         for (uint i = 0; i < tokenIds.length; i++) {
             stake(collection, tokenIds[i], permanent);
         }
     }

     // unstake
     function unstake(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
         // unstake bookkeeping and require term passed inside lib; lib returns unstake fee required
         uint256 fee = staking._recordUnstake(collection, _msgSender(), tokenId, config);
         // fee payable via immutable split (burn/treasury/deployer)
         require(balanceOf(_msgSender()) >= fee, "insufficient CATA for unstake fee");
         _splitFeeFromSender(_msgSender(), fee, collection, true);

         // transfer NFT back
         IERC721(collection).safeTransferFrom(address(this), _msgSender(), tokenId);
         emit NFTUnstaked(_msgSender(), collection, tokenId);
     }

     // harvest single
     function harvest(address collection, uint256 tokenId) external nonReentrant whenNotPaused {
         // compute pending reward; library computes reward amount and burn portion
         (uint256 reward, uint256 burnAmt) = staking._harvestAndCompute(collection, _msgSender(), tokenId, config);
         if (reward == 0) return;
         // mint full reward to user (the merged contract minted then burned)
         _mint(_msgSender(), reward);
         // apply burn portion from user (burning from minted reward)
         if (burnAmt > 0) {
             // burn from user (they just received reward)
             _burn(_msgSender(), burnAmt);
             // track burned amounts per collection & user
             staking.burnedCatalystByCollection[collection] += burnAmt;
             staking._recordUserBurn(_msgSender(), burnAmt);
             // update top collections bookkeeping
             staking._updateTopCollectionsOnBurn(collection);
         }
         emit RewardsHarvested(_msgSender(), collection, reward - burnAmt, burnAmt);
     }

     // harvest batch
     function harvestBatch(address collection, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
         require(tokenIds.length > 0 && tokenIds.length <= StakingLib.MAX_BATCH, "bad batch");
         for (uint i = 0; i < tokenIds.length; i++) {
             harvest(collection, tokenIds[i]);
         }
     }

     // --------------------
     // REGISTRATION
     // --------------------

     // permissionless register (same semantics as merged)
     function registerCollection(address collection, uint256 declaredMaxSupply, ConfigRegistryLib.CollectionTier requestedTier) external nonReentrant whenNotPaused {
         (uint256 baseFee, uint256 surcharge) = config._computeRegistrationFees(declaredMaxSupply, requestedTier);
         uint256 total = baseFee + surcharge;
         require(balanceOf(_msgSender()) >= total, "insufficient CATA");

         // split baseFee immutably
         _splitFeeFromSender(_msgSender(), baseFee, collection, true);

         // move surcharge escrow to internal accounting (contract already holds tokens, transfer payer->contract)
         if (surcharge > 0) {
             _transfer(_msgSender(), address(this), surcharge);
         }

         // register in staking.storage
         staking._registerCollection(collection, declaredMaxSupply, requestedTier, _msgSender(), surcharge);

         // update top collections
         staking._updateTopCollectionsOnBurn(collection);
         staking._maybeRebuildTopCollections();

         emit CollectionAdded(collection, declaredMaxSupply, baseFee, surcharge, requestedTier);
     }

     // admin registration (keeps previous behavior)
     function setCollectionConfig(address collection, uint256 declaredMaxSupply, ConfigRegistryLib.CollectionTier tier) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
         (uint256 baseFee, uint256 surcharge) = config._computeRegistrationFees(declaredMaxSupply, tier);
         require(balanceOf(_msgSender()) >= baseFee + surcharge, "insuff balance");
         _splitFeeFromSender(_msgSender(), baseFee, collection, true);
         if (surcharge > 0) _transfer(_msgSender(), address(this), surcharge);

         staking._registerCollection(collection, declaredMaxSupply, tier, _msgSender(), surcharge);
         staking._updateTopCollectionsOnBurn(collection);
         staking._maybeRebuildTopCollections();

         emit CollectionAdded(collection, declaredMaxSupply, baseFee, surcharge, tier);
     }

     // remove collection
     function removeCollection(address collection) external onlyRole(CONTRACT_ADMIN_ROLE) whenNotPaused {
         staking._removeCollection(collection);
     }

     // --------------------
     // GOVERNANCE
     // --------------------

     function propose(
         GovernanceLib.ProposalType pType,
         uint8 paramTarget,
         uint256 newValue,
         address collectionContext
     ) external whenNotPaused returns (bytes32) {
         bytes32 id = governance._createProposal(pType, paramTarget, newValue, collectionContext, _msgSender(), config, staking);
         emit ProposalCreated(id, pType, paramTarget, collectionContext, _msgSender(), newValue, block.number, block.number + governance.votingDurationBlocks);
         return id;
     }

     function vote(bytes32 id) external whenNotPaused {
         (uint256 weight, address attributedCollection) = governance._castVote(id, _msgSender(), staking, config);
         emit VoteCast(id, _msgSender(), weight, attributedCollection);
     }

     function executeProposal(bytes32 id) external whenNotPaused nonReentrant {
         ProposalExecutorLib.ExecContext memory ctx = ProposalExecutorLib.ExecContext({
             core: this,
             governanceStorage: governance,
             configStorage: config,
             stakingStorage: staking
         });
         ProposalExecutorLib._execute(ctx, id);
         emit ProposalExecuted(id, 1);
     }

     // --------------------
     // TREASURY
     // --------------------

     // internal deposit called when fee split sends to contract
     function _recordTreasuryDeposit(uint256 amount) internal {
         treasury._deposit(amount);
         feeState.treasuryBalance += amount;
         emit TreasuryLib.TreasuryDeposit(address(this), amount);
     }

     // treasury withdrawal: core performs ERC20 transfer from contract -> to
     function withdrawTreasury(address to, uint256 amount) external onlyRole(CONTRACT_ADMIN_ROLE) nonReentrant whenNotPaused {
         require(to != address(0), "bad to");
         require(amount > 0, "zero");
         require(amount <= treasury.balance, "insuff treasury");
         treasury._withdraw(to, amount, IERC20(address(this)));
     }

     // --------------------
     // FEE SPLIT (immutable 90/9/1)
     // --------------------
     // same behavior as your merged contract: burn 90%, treasury 9%, deployer 1%
     function _splitFeeFromSender(address payer, uint256 amount, address collection, bool attributeToUser) internal {
         require(amount > 0, "zero fee");
         uint256 burnAmt = (amount * 9000) / 10000;
         uint256 treasuryAmt = (amount * 900) / 10000;
         uint256 deployerAmt = amount - burnAmt - treasuryAmt;

         // burn from payer
         if (burnAmt > 0) {
             _burn(payer, burnAmt);
             staking.burnedCatalystByCollection[collection] += burnAmt;
             if (attributeToUser) staking._recordUserBurn(payer, burnAmt);
         }

         // transfer deployer share
         if (deployerAmt > 0) {
             _transfer(payer, deployerAddress, deployerAmt);
         }

         // transfer treasury share into contract and account it
         if (treasuryAmt > 0) {
             _transfer(payer, address(this), treasuryAmt);
             _recordTreasuryDeposit(treasuryAmt);
         }
     }

     // --------------------
     // ADMIN SETTERS (selected)
     // --------------------
     function pause() external onlyRole(CONTRACT_ADMIN_ROLE) { _pause(); }
     function unpause() external onlyRole(CONTRACT_ADMIN_ROLE) { _unpause(); }

     function addContractAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
         grantRole(CONTRACT_ADMIN_ROLE, admin);
     }
     function removeContractAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
         revokeRole(CONTRACT_ADMIN_ROLE, admin);
     }

     // UUPS authorize
     function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

     // ERC721 receiver
     function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
         return this.onERC721Received.selector;
     }
 }
