// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GovernanceLib
/// @notice Burn-Weighted Collection Governance (BWCG) with stake-age gating,
///         per-collection vote caps, quorum, and proposal lifecycle.
/// @dev Library-only logic: the upgradeable core is responsible for
///      - computing voter weights (e.g., by burned CATA + stake-age multipliers),
///      - enforcing role checks (onlyGovernance, onlyAdmin),
///      - executing actions via ProposalExecutorLib (not in this file).
library GovernanceLib {
    // ====== CUSTOM ERRORS ======
    error NotActive();
    error AlreadyVoted();
    error Ineligible();
    error ZeroWeight();
    error InvalidSupport();
    error CapExceeded();
    error AlreadyExecuted();
    error Canceled();
    error NotSucceeded();
    error TooEarly();
    error TooLate();
    error NoVotesYet();
    error ParamOutOfBounds();

    // ====== TYPES ======
    enum ProposalState {
        Pending,      // created, before startBlock
        Active,       // between startBlock and endBlock
        Defeated,     // voting ended, did not pass
        Succeeded,    // voting ended, passed quorum & majority
        Executable,   // passed and after endBlock (ready to execute)
        Executed,     // executed
        Canceled,     // canceled by proposer/admin before voting really started
        Expired       // succeeded but execution window expired (optional semantics)
    }

    /// @dev Support choices mirror OpenZeppelin Governor (0=Against, 1=For, 2=Abstain)
    enum Support { Against, For, Abstain }

    struct Proposal {
        uint256 id;
        address proposer;
        uint48  startBlock;
        uint48  endBlock;
        uint16  quorumBP;                 // basis points of total voting weight
        uint16  collectionCapBP;          // per-collection weight cap in BP of total supply
        uint32  minStakeAgeBlocks;        // stake-age requirement
        bool    executed;
        bool    canceled;

        // Tallies
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;

        // Off-chain integrity anchors
        bytes32 descriptionHash;          // keccak256 of human text / metadata
        bytes32 actionsHash;              // keccak256 of encoded actions bundle
    }

    struct Receipt {
        bool    hasVoted;
        uint8   support;                  // cast Support as uint8
        uint256 weight;                   // counted (may be capped)
        uint256 collectionId;             // collection attribution of weight
    }

    /// @dev Global, protocol-wide governance parameters (defaults)
    struct Params {
        uint16  defaultQuorumBP;          // e.g., 4000 = 40%
        uint16  defaultCollectionCapBP;   // e.g., 2000 = 20% max per collection per proposal
        uint32  defaultMinStakeAgeBlocks; // e.g., ~3 days
        uint32  votingPeriodBlocks;       // e.g., ~1 week
        uint32  executionGraceBlocks;     // optional grace after endBlock to execute
    }

    /// @dev Library storage (kept inside the core contract's storage)
    struct Storage {
        uint256 proposalCount;
        mapping(uint256 => Proposal) proposals;
        mapping(uint256 => mapping(address => Receipt)) receipts;
        // Per-proposal, per-collection weight accounting (to enforce collection cap)
        mapping(uint256 => mapping(uint256 => uint256)) usedWeightByCollection;
        Params params;
    }

    // ====== EVENTS ======
    event GovernanceParamsUpdated(
        uint16 defaultQuorumBP,
        uint16 defaultCollectionCapBP,
        uint32 defaultMinStakeAgeBlocks,
        uint32 votingPeriodBlocks,
        uint32 executionGraceBlocks
    );

    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        uint48 startBlock,
        uint48 endBlock,
        uint16 quorumBP,
        uint16 collectionCapBP,
        uint32 minStakeAgeBlocks,
        bytes32 descriptionHash,
        bytes32 actionsHash
    );

    event VoteCast(
        uint256 indexed id,
        address indexed voter,
        uint8 support,
        uint256 weight,
        uint256 collectionId
    );

    event ProposalCanceled(uint256 indexed id, address indexed by);
    event ProposalExecuted(uint256 indexed id, address indexed executor);

    // ====== PARAM MANAGEMENT ======

    /// @notice Initialize default governance parameters
    function initParams(
        Storage storage s,
        uint16  defaultQuorumBP,
        uint16  defaultCollectionCapBP,
        uint32  defaultMinStakeAgeBlocks,
        uint32  votingPeriodBlocks,
        uint32  executionGraceBlocks
    ) internal {
        _validateParams(defaultQuorumBP, defaultCollectionCapBP);
        s.params = Params({
            defaultQuorumBP: defaultQuorumBP,
            defaultCollectionCapBP: defaultCollectionCapBP,
            defaultMinStakeAgeBlocks: defaultMinStakeAgeBlocks,
            votingPeriodBlocks: votingPeriodBlocks,
            executionGraceBlocks: executionGraceBlocks
        });
        emit GovernanceParamsUpdated(
            defaultQuorumBP,
            defaultCollectionCapBP,
            defaultMinStakeAgeBlocks,
            votingPeriodBlocks,
            executionGraceBlocks
        );
    }

    /// @notice Update default governance parameters
    /// @dev Caller permissions enforced by the core.
    function updateParams(
        Storage storage s,
        uint16  defaultQuorumBP,
        uint16  defaultCollectionCapBP,
        uint32  defaultMinStakeAgeBlocks,
        uint32  votingPeriodBlocks,
        uint32  executionGraceBlocks
    ) internal {
        _validateParams(defaultQuorumBP, defaultCollectionCapBP);
        s.params.defaultQuorumBP = defaultQuorumBP;
        s.params.defaultCollectionCapBP = defaultCollectionCapBP;
        s.params.defaultMinStakeAgeBlocks = defaultMinStakeAgeBlocks;
        s.params.votingPeriodBlocks = votingPeriodBlocks;
        s.params.executionGraceBlocks = executionGraceBlocks;

        emit GovernanceParamsUpdated(
            defaultQuorumBP,
            defaultCollectionCapBP,
            defaultMinStakeAgeBlocks,
            votingPeriodBlocks,
            executionGraceBlocks
        );
    }

    function _validateParams(uint16 quorumBP, uint16 collectionCapBP) private pure {
        if (quorumBP == 0 || quorumBP > 10000) revert ParamOutOfBounds();
        if (collectionCapBP == 0 || collectionCapBP > 10000) revert ParamOutOfBounds();
    }

    // ====== PROPOSALS ======

    /// @notice Create a proposal with default params
    /// @param proposer The proposer address (core enforces who can propose)
    /// @param descriptionHash keccak256 of the human-readable description
    /// @param actionsHash keccak256 of encoded actions bundle (to execute later)
    /// @return id New proposal id
    function propose(
        Storage storage s,
        address proposer,
        bytes32 descriptionHash,
        bytes32 actionsHash
    ) internal returns (uint256 id) {
        id = ++s.proposalCount;

        uint48 start = uint48(block.number);
        uint48 end   = start + uint48(s.params.votingPeriodBlocks);

        Proposal storage p = s.proposals[id];
        p.id = id;
        p.proposer = proposer;
        p.startBlock = start;
        p.endBlock   = end;
        p.quorumBP   = s.params.defaultQuorumBP;
        p.collectionCapBP    = s.params.defaultCollectionCapBP;
        p.minStakeAgeBlocks  = s.params.defaultMinStakeAgeBlocks;
        p.descriptionHash    = descriptionHash;
        p.actionsHash        = actionsHash;

        emit ProposalCreated(
            id, proposer, start, end, p.quorumBP, p.collectionCapBP, p.minStakeAgeBlocks, descriptionHash, actionsHash
        );
    }

    /// @notice Create a proposal with custom quorum / caps / stake-age for this proposal only
    function proposeCustom(
        Storage storage s,
        address proposer,
        bytes32 descriptionHash,
        bytes32 actionsHash,
        uint16 quorumBP,
        uint16 collectionCapBP,
        uint32 minStakeAgeBlocks
    ) internal returns (uint256 id) {
        _validateParams(quorumBP, collectionCapBP);

        id = ++s.proposalCount;
        uint48 start = uint48(block.number);
        uint48 end   = start + uint48(s.params.votingPeriodBlocks);

        Proposal storage p = s.proposals[id];
        p.id = id;
        p.proposer = proposer;
        p.startBlock = start;
        p.endBlock   = end;
        p.quorumBP   = quorumBP;
        p.collectionCapBP   = collectionCapBP;
        p.minStakeAgeBlocks = minStakeAgeBlocks;
        p.descriptionHash   = descriptionHash;
        p.actionsHash       = actionsHash;

        emit ProposalCreated(
            id, proposer, start, end, p.quorumBP, p.collectionCapBP, p.minStakeAgeBlocks, descriptionHash, actionsHash
        );
    }

    // ====== VOTING ======

    /// @notice Cast a vote with weight & eligibility precomputed by the core
    /// @param id Proposal id
    /// @param voter voter address
    /// @param support 0=Against, 1=For, 2=Abstain
    /// @param rawWeight voter weight computed by core (e.g., burn-weighted, stake-age multiplier applied there if desired)
    /// @param eligible core-checked stake-age eligibility (true if voter meets minStakeAgeBlocks)
    /// @param collectionId primary collection attribution of the voter's weight
    /// @param totalWeightSupply total voting weight supply snapshot computed by core for this proposal window
    /// @return countedWeight the weight that was actually counted (after per-collection cap)
    function castVote(
        Storage storage s,
        uint256 id,
        address voter,
        uint8   support,
        uint256 rawWeight,
        bool    eligible,
        uint256 collectionId,
        uint256 totalWeightSupply
    ) internal returns (uint256 countedWeight) {
        Proposal storage p = s.proposals[id];

        if (p.canceled) revert Canceled();
        if (p.executed) revert AlreadyExecuted();
        if (block.number < p.startBlock) revert TooEarly();
        if (block.number > p.endBlock) revert TooLate();
        if (support > uint8(Support.Abstain)) revert InvalidSupport();

        Receipt storage r = s.receipts[id][voter];
        if (r.hasVoted) revert AlreadyVoted();
        if (!eligible) revert Ineligible();
        if (rawWeight == 0) revert ZeroWeight();

        // Enforce per-collection cap: max cap for this collection for this proposal
        // cap = totalWeightSupply * collectionCapBP / 10000
        uint256 capForCollection = (totalWeightSupply * uint256(p.collectionCapBP)) / 10_000;
        uint256 used = s.usedWeightByCollection[id][collectionId];
        uint256 remaining = capForCollection > used ? (capForCollection - used) : 0;
        if (remaining == 0) revert CapExceeded();

        countedWeight = rawWeight > remaining ? remaining : rawWeight;

        // Record receipt
        r.hasVoted = true;
        r.support = support;
        r.weight = countedWeight;
        r.collectionId = collectionId;

        // Update usage
        s.usedWeightByCollection[id][collectionId] = used + countedWeight;

        // Tally
        if (support == uint8(Support.For)) {
            p.forVotes += countedWeight;
        } else if (support == uint8(Support.Against)) {
            p.againstVotes += countedWeight;
        } else {
            p.abstainVotes += countedWeight;
        }

        emit VoteCast(id, voter, support, countedWeight, collectionId);
    }

    // ====== STATE / TALLY ======

    /// @notice Compute current state (needs totalWeightSupply snapshot from core)
    function state(
        Storage storage s,
        uint256 id,
        uint256 totalWeightSupply
    ) internal view returns (ProposalState) {
        Proposal storage p = s.proposals[id];

        if (p.canceled) return ProposalState.Canceled;
        if (p.executed) return ProposalState.Executed;
        if (block.number < p.startBlock) return ProposalState.Pending;
        if (block.number <= p.endBlock) return ProposalState.Active;

        // After end: determine pass/fail
        (bool passed, bool quorumMet) = _tally(p, totalWeightSupply);
        if (!passed) return ProposalState.Defeated;

        // Succeeded
        // If within execution grace, mark as Executable; else Expired (optional pattern)
        if (block.number <= (uint256(p.endBlock) + s.params.executionGraceBlocks)) {
            return ProposalState.Executable;
        } else {
            return ProposalState.Expired;
        }
    }

    function _tally(
        Proposal storage p,
        uint256 totalWeightSupply
    ) private view returns (bool passed, bool quorumMet) {
        // quorum: forVotes + abstainVotes can count as participation or only forVotes?
        // Commonly quorum is based on "for + against + abstain" participation or just "for".
        // Here we define quorum on total participation (for + against + abstain).
        uint256 participation = p.forVotes + p.againstVotes + p.abstainVotes;
        quorumMet = participation >= ((totalWeightSupply * uint256(p.quorumBP)) / 10_000);

        // majority: "for" strictly greater than "against"
        bool majority = p.forVotes > p.againstVotes;

        passed = quorumMet && majority;
    }

    /// @notice View helper returning tallies & quorum status
    function tallies(
        Storage storage s,
        uint256 id,
        uint256 totalWeightSupply
    ) internal view returns (
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes,
        bool quorumMet,
        bool majority,
        bool passed
    ) {
        Proposal storage p = s.proposals[id];
        forVotes = p.forVotes;
        againstVotes = p.againstVotes;
        abstainVotes = p.abstainVotes;

        uint256 participation = forVotes + againstVotes + abstainVotes;
        quorumMet = participation >= ((totalWeightSupply * uint256(p.quorumBP)) / 10_000);
        majority  = forVotes > againstVotes;
        passed    = quorumMet && majority;
    }

    // ====== ADMIN / LIFECYCLE ======

    /// @notice Cancel a proposal (e.g., by proposer or admin) before any vote was cast
    /// @dev Core must enforce who may call this (proposer, admin, etc.)
    function cancel(Storage storage s, uint256 id, address by) internal {
        Proposal storage p = s.proposals[id];
        if (p.canceled) revert Canceled();
        if (p.executed) revert AlreadyExecuted();
        if (block.number > p.startBlock) {
            // allow cancel only if no votes have been cast yet
            if ((p.forVotes + p.againstVotes + p.abstainVotes) > 0) revert NotActive();
        }
        p.canceled = true;
        emit ProposalCanceled(id, by);
    }

    /// @notice Marks proposal as executed after core successfully runs actions
    /// @dev Requires: state == Executable and passed tally
    function markExecuted(
        Storage storage s,
        uint256 id,
        uint256 totalWeightSupply
    ) internal {
        Proposal storage p = s.proposals[id];
        if (p.canceled) revert Canceled();
        if (p.executed) revert AlreadyExecuted();
        if (block.number <= p.endBlock) revert TooEarly();

        (bool passed, ) = _tally(p, totalWeightSupply);
        if (!passed) revert NotSucceeded();

        p.executed = true;
        emit ProposalExecuted(id, msg.sender);
    }

    // ====== READ HELPERS ======

    function getProposal(Storage storage s, uint256 id) internal view returns (Proposal memory) {
        return s.proposals[id];
    }

    function getReceipt(Storage storage s, uint256 id, address voter) internal view returns (Receipt memory) {
        return s.receipts[id][voter];
    }

    function params(Storage storage s) internal view returns (Params memory) {
        return s.params;
    }
}
