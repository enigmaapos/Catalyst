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
        require(collectionVoteCapPercent_ <= 100, "GovernanceLib: cap>100");
        g.votingDurationBlocks = votingDurationBlocks_;
        g.minVotesRequiredScaled = minVotesRequiredScaled_;
        g.collectionVoteCapPercent = collectionVoteCapPercent_;
    }

    function createProposal(
        Storage storage g,
        ProposalType pType,
        uint8 paramTarget,
        uint256 newValue,
        address collection,
        address proposer,
        uint256 currentBlock
    ) internal returns (bytes32) {
        bytes32 id = keccak256(
            abi.encodePacked(uint256(pType), paramTarget, newValue, collection, currentBlock, proposer)
        );
        Proposal storage p = g.proposals[id];
        require(p.startBlock == 0, "GovernanceLib: exists");

        p.pType = pType;
        p.paramTarget = paramTarget;
        p.newValue = newValue;
        p.collectionAddress = collection;
        p.proposer = proposer;
        p.startBlock = currentBlock;
        p.endBlock = currentBlock + g.votingDurationBlocks;
        p.votesScaled = 0;
        p.executed = false;

        emit ProposalCreated(id, pType, paramTarget, collection, proposer, newValue, p.startBlock, p.endBlock);
        return id;
    }

    function castVote(
        Storage storage g,
        bytes32 id,
        address voter,
        uint256 weightScaled,
        address attributedCollection
    ) internal {
        Proposal storage p = g.proposals[id];
        require(p.startBlock != 0, "GovernanceLib: not found");
        require(block.number >= p.startBlock && block.number <= p.endBlock, "GovernanceLib: closed");
        require(!p.executed, "GovernanceLib: executed");
        require(!g.hasVoted[id][voter], "GovernanceLib: voted");
        require(weightScaled > 0, "GovernanceLib: zero weight");

        uint256 collectionVoteCapPercent = g.collectionVoteCapPercent;
        uint256 minVotesRequiredScaled = g.minVotesRequiredScaled;
        uint256 cap = (minVotesRequiredScaled * collectionVoteCapPercent) / 100;
        uint256 cur = g.proposalCollectionVotesScaled[id][attributedCollection];

        require(cur + weightScaled <= cap, "GovernanceLib: cap");

        g.hasVoted[id][voter] = true;
        p.votesScaled += weightScaled;
        g.proposalCollectionVotesScaled[id][attributedCollection] = cur + weightScaled;

        emit VoteCast(id, voter, weightScaled, attributedCollection);
    }

    /// @notice Validate execution conditions; does not mark executed
    function validateForExecution(Storage storage g, bytes32 id) internal view returns (Proposal memory) {
        Proposal memory p = g.proposals[id];
        require(p.startBlock != 0, "GovernanceLib: not found");
        require(block.number > p.endBlock, "GovernanceLib: voting");
        require(!p.executed, "GovernanceLib: executed");
        require(p.votesScaled >= g.minVotesRequiredScaled, "GovernanceLib: quorum");
        return p;
    }

    /// @notice Mark executed separately
    function markExecuted(Storage storage g, bytes32 id) internal {
        g.proposals[id].executed = true;
        emit ProposalMarkedExecuted(id);
    }
}
