// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Governance bookkeeping library (create + vote + validate execute).
library GovernanceLib {
    // Custom errors for gas efficiency
    error ProposalExists();
    error NoDuration();
    error NotFound();
    error VotingClosed();
    error AlreadyExecuted();
    error AlreadyVoted();
    error ZeroWeight();
    error CapReached();
    error VotingInProgress();
    error QuorumNotMet();

    enum ProposalType {
        BASE_REWARD,
        HARVEST_FEE,
        UNSTAKE_FEE,
        REGISTRATION_FEE_FALLBACK,
        VOTING_PARAM,
        TIER_UPGRADE
    }

    struct Proposal {
        ProposalType pType;
        uint8 paramTarget;
        uint256 newValue;
        address collectionAddress;
        address proposer;
        uint256 startBlock;
        uint256 endBlock;
        uint256 votesScaled;
        bool executed;
    }

    struct Storage {
        mapping(bytes32 => Proposal) proposals;
        mapping(bytes32 => mapping(address => bool)) hasVoted;
        mapping(bytes32 => mapping(address => uint256)) proposalCollectionVotesScaled;
        uint256 votingDurationBlocks;
        uint256 minVotesRequiredScaled;
        uint256 collectionVoteCapPercent; // percent 0..100
    }

    event ProposalCreated(
        bytes32 indexed id,
        ProposalType pType,
        uint8 paramTarget,
        address indexed collection,
        address indexed proposer,
        uint256 newValue,
        uint256 startBlock,
        uint256 endBlock
    );
    event VoteCast(bytes32 indexed id, address indexed voter, uint256 weightScaled, address attributedCollection);
    event ProposalMarkedExecuted(bytes32 indexed id);

    function initGov(
        Storage storage g,
        uint256 votingDurationBlocks_,
        uint256 minVotesRequiredScaled_,
        uint256 collectionVoteCapPercent_
    ) internal {
        if (collectionVoteCapPercent_ > 100) revert CapReached();
        g.votingDurationBlocks = votingDurationBlocks_;
        g.minVotesRequiredScaled = minVotesRequiredScaled_;
        g.collectionVoteCapPercent = collectionVoteCapPercent_;
    }

    function create(
        Storage storage g,
        bytes32 id,
        ProposalType pType,
        uint8 paramTarget,
        address collectionAddress,
        uint256 newValue,
        address proposer,
        uint256 durationBlocks,
        uint256 minVotesRequired
    ) internal {
        if (g.proposals[id].startBlock != 0) revert ProposalExists();
        if (durationBlocks == 0) revert NoDuration();

        g.minVotesRequiredScaled = (minVotesRequired * 10**18) / 10**8;

        g.proposals[id] = Proposal({
            pType: pType,
            paramTarget: paramTarget,
            newValue: newValue,
            collectionAddress: collectionAddress,
            proposer: proposer,
            startBlock: block.number,
            endBlock: block.number + durationBlocks,
            votesScaled: 0,
            executed: false
        });

        emit ProposalCreated(
            id,
            pType,
            paramTarget,
            collectionAddress,
            proposer,
            newValue,
            block.number,
            block.number + durationBlocks
        );
    }

    function vote(
        Storage storage g,
        bytes32 id,
        address voter,
        uint256 weightScaled,
        address attributedCollection
    ) internal {
        Proposal storage p = g.proposals[id];
        if (p.startBlock == 0) revert NotFound();
        if (block.number < p.startBlock || block.number > p.endBlock) revert VotingClosed();
        if (p.executed) revert AlreadyExecuted();
        if (g.hasVoted[id][voter]) revert AlreadyVoted();
        if (weightScaled == 0) revert ZeroWeight();

        uint256 cap = (g.minVotesRequiredScaled * g.collectionVoteCapPercent) / 100;
        uint256 cur = g.proposalCollectionVotesScaled[id][attributedCollection];
        if (cur + weightScaled > cap) revert CapReached();

        g.hasVoted[id][voter] = true;
        p.votesScaled += weightScaled;
        g.proposalCollectionVotesScaled[id][attributedCollection] = cur + weightScaled;

        emit VoteCast(id, voter, weightScaled, attributedCollection);
    }

    /// @notice Validate execution conditions; does not mark executed
    function validateForExecution(Storage storage g, bytes32 id) internal view returns (Proposal memory) {
        Proposal memory p = g.proposals[id];
        if (p.startBlock == 0) revert NotFound();
        if (block.number <= p.endBlock) revert VotingInProgress();
        if (p.executed) revert AlreadyExecuted();
        if (p.votesScaled < g.minVotesRequiredScaled) revert QuorumNotMet();
        return p;
    }

    /// @notice Mark executed separately
    function markExecuted(Storage storage g, bytes32 id) internal {
        g.proposals[id].executed = true;
        emit ProposalMarkedExecuted(id);
    }
}
