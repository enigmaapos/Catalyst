// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Governance bookkeeping library (create + vote + validate execute).
library GovernanceLib {
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

    // --- Custom errors (save bytecode & gas) ---
    error ProposalExists();
    error ProposalNotFound();
    error VotingClosed();
    error AlreadyExecuted();
    error AlreadyVoted();
    error ZeroWeight();
    error CapExceeded();
    error VotingNotEnded();
    error QuorumNotMet();
    error CapTooHigh();

    // --- Events ---
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

    // --- Init ---
    function initGov(
        Storage storage g,
        uint256 votingDurationBlocks_,
        uint256 minVotesRequiredScaled_,
        uint256 collectionVoteCapPercent_
    ) internal {
        if (collectionVoteCapPercent_ > 100) revert CapTooHigh();
        g.votingDurationBlocks = votingDurationBlocks_;
        g.minVotesRequiredScaled = minVotesRequiredScaled_;
        g.collectionVoteCapPercent = collectionVoteCapPercent_;
    }

    // --- Proposal creation ---
    function createProposal(
        Storage storage g,
        ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collection,
        address proposer,
        uint256 currentBlock
    ) internal returns (bytes32 id) {
        id = keccak256(
            abi.encodePacked(uint256(pType), paramTarget, newValue, collection, currentBlock, proposer)
        );
        Proposal storage p = g.proposals[id];
        if (p.startBlock != 0) revert ProposalExists();

        p.pType = pType;
        p.paramTarget = paramTarget;
        p.newValue = newValue;
        p.collectionAddress = collection;
        p.proposer = proposer;
        p.startBlock = currentBlock;
        p.endBlock = currentBlock + g.votingDurationBlocks;

        emit ProposalCreated(id, pType, paramTarget, collection, proposer, newValue, p.startBlock, p.endBlock);
    }

    // --- Voting ---
    function castVote(
        Storage storage g,
        bytes32 id,
        address voter,
        uint256 weightScaled,
        address attributedCollection
    ) internal {
        Proposal storage p = g.proposals[id];
        if (p.startBlock == 0) revert ProposalNotFound();
        if (block.number < p.startBlock || block.number > p.endBlock) revert VotingClosed();
        if (p.executed) revert AlreadyExecuted();
        if (g.hasVoted[id][voter]) revert AlreadyVoted();
        if (weightScaled == 0) revert ZeroWeight();

        uint256 cap = (g.minVotesRequiredScaled * g.collectionVoteCapPercent) / 100;
        uint256 cur = g.proposalCollectionVotesScaled[id][attributedCollection];
        if (cur + weightScaled > cap) revert CapExceeded();

        g.hasVoted[id][voter] = true;
        p.votesScaled += weightScaled;
        g.proposalCollectionVotesScaled[id][attributedCollection] = cur + weightScaled;

        emit VoteCast(id, voter, weightScaled, attributedCollection);
    }

    // --- Execution validation ---
    function validateForExecution(Storage storage g, bytes32 id) internal view returns (Proposal memory p) {
        p = g.proposals[id];
        if (p.startBlock == 0) revert ProposalNotFound();
        if (block.number <= p.endBlock) revert VotingNotEnded();
        if (p.executed) revert AlreadyExecuted();
        if (p.votesScaled < g.minVotesRequiredScaled) revert QuorumNotMet();
    }

    // --- Mark executed ---
    function markExecuted(Storage storage g, bytes32 id) internal {
        Proposal storage p = g.proposals[id];
        if (p.executed) revert AlreadyExecuted();
        p.executed = true;
        emit ProposalMarkedExecuted(id);
    }
}
