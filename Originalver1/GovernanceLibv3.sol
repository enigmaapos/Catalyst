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

    function init(
        Storage storage g,
        uint256 votingDurationBlocks_,
        uint256 minVotesRequiredScaled_,
        uint256 collectionVoteCapPercent_
    ) external {
        require(collectionVoteCapPercent_ <= 100, "GovernanceLib: cap>100");
        g.votingDurationBlocks = votingDurationBlocks_;
        g.minVotesRequiredScaled = minVotesRequiredScaled_;
        g.collectionVoteCapPercent = collectionVoteCapPercent_;
    }

    function createProposal(
        Storage storage g,
        bytes32 id,
        ProposalType pType,
        uint8 paramTarget,
        address collection,
        address proposer,
        uint256 newValue,
        uint256 startBlock,
        uint256 endBlock
    ) external {
        require(g.proposals[id].startBlock == 0, "GovernanceLib: already exists");
        require(collection != address(0), "GovernanceLib: zero collection");
        require(proposer != address(0), "GovernanceLib: zero proposer");
        require(startBlock > block.number, "GovernanceLib: not in future");
        require(endBlock > startBlock, "GovernanceLib: bad range");

        g.proposals[id] = Proposal({
            pType: pType,
            paramTarget: paramTarget,
            newValue: newValue,
            collectionAddress: collection,
            proposer: proposer,
            startBlock: startBlock,
            endBlock: endBlock,
            votesScaled: 0,
            executed: false
        });

        emit ProposalCreated(id, pType, paramTarget, collection, proposer, newValue, startBlock, endBlock);
    }

    function vote(
        Storage storage g,
        bytes32 id,
        address voter,
        uint256 weightScaled,
        address attributedCollection
    ) external {
        Proposal storage p = g.proposals[id];
        require(p.startBlock != 0, "GovernanceLib: not found");
        require(block.number >= p.startBlock && block.number <= p.endBlock, "GovernanceLib: closed");
        require(!p.executed, "GovernanceLib: executed");
        require(!g.hasVoted[id][voter], "GovernanceLib: voted");
        require(weightScaled > 0, "GovernanceLib: zero weight");

        uint256 cap = (g.minVotesRequiredScaled * g.collectionVoteCapPercent) / 100;
        uint256 cur = g.proposalCollectionVotesScaled[id][attributedCollection];
        require(cur + weightScaled <= cap, "GovernanceLib: cap");

        g.hasVoted[id][voter] = true;
        p.votesScaled += weightScaled;
        g.proposalCollectionVotesScaled[id][attributedCollection] = cur + weightScaled;

        emit VoteCast(id, voter, weightScaled, attributedCollection);
    }

    function validateForExecution(Storage storage g, bytes32 id) external view returns (Proposal memory) {
        Proposal memory p = g.proposals[id];
        require(p.startBlock != 0, "GovernanceLib: not found");
        require(block.number > p.endBlock, "GovernanceLib: voting");
        require(!p.executed, "GovernanceLib: executed");
        require(p.votesScaled >= g.minVotesRequiredScaled, "GovernanceLib: quorum");
        return p;
    }

    function markExecuted(Storage storage g, bytes32 id) external {
        g.proposals[id].executed = true;
        emit ProposalMarkedExecuted(id);
    }
}
