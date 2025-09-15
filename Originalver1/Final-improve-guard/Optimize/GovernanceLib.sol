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

    error ZeroAddress();
    error BadParam();
    error NotFound();
    error ProposalClosed();
    error AlreadyExecuted();
    error AlreadyVoted();
    error ZeroWeight();
    error QuorumNotMet();
    error VotingStillOpen();

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

    function createProposal(
        Storage storage g,
        ProposalType _pType,
        uint8 _paramTarget,
        uint256 _newValue,
        address _collectionAddress,
        address _proposer
    ) internal returns (bytes32 id) {
        id = keccak256(abi.encode(_pType, _paramTarget, _newValue, _collectionAddress, _proposer, block.number));
        if (g.proposals[id].startBlock != 0) { revert AlreadyExists(); }
        if (_proposer == address(0)) { revert ZeroAddress(); }

        g.proposals[id] = Proposal({
            pType: _pType,
            paramTarget: _paramTarget,
            newValue: _newValue,
            collectionAddress: _collectionAddress,
            proposer: _proposer,
            startBlock: block.number,
            endBlock: block.number + g.votingDurationBlocks,
            votesScaled: 0,
            executed: false
        });

        emit ProposalCreated(
            id,
            _pType,
            _paramTarget,
            _collectionAddress,
            _proposer,
            _newValue,
            block.number,
            block.number + g.votingDurationBlocks
        );
    }

    function castVote(
        Storage storage g,
        bytes32 id,
        address voter,
        uint256 weightScaled,
        address attributedCollection
    ) internal {
        Proposal storage p = g.proposals[id];
        if (p.startBlock == 0) { revert NotFound(); }
        if (block.number < p.startBlock || block.number > p.endBlock) { revert ProposalClosed(); }
        if (p.executed) { revert AlreadyExecuted(); }
        if (g.hasVoted[id][voter]) { revert AlreadyVoted(); }
        if (weightScaled == 0) { revert ZeroWeight(); }
        if (g.collectionVoteCapPercent > 0 && attributedCollection != address(0)) {
            uint256 cap = (g.minVotesRequiredScaled * g.collectionVoteCapPercent) / 100;
            uint256 cur = g.proposalCollectionVotesScaled[id][attributedCollection];
            if (cur + weightScaled > cap) { revert BadParam(); } // Reverting with a generic error as the original string message is not in a custom error
        }

        g.hasVoted[id][voter] = true;
        p.votesScaled += weightScaled;
        g.proposalCollectionVotesScaled[id][attributedCollection] += weightScaled;

        emit VoteCast(id, voter, weightScaled, attributedCollection);
    }

    function validateForExecution(Storage storage g, bytes32 id) internal view returns (Proposal memory) {
        Proposal memory p = g.proposals[id];
        if (p.startBlock == 0) { revert NotFound(); }
        if (block.number <= p.endBlock) { revert VotingStillOpen(); }
        if (p.executed) { revert AlreadyExecuted(); }
        if (p.votesScaled < g.minVotesRequiredScaled) { revert QuorumNotMet(); }
        return p;
    }

    function markExecuted(Storage storage g, bytes32 id) internal {
        g.proposals[id].executed = true;
        emit ProposalMarkedExecuted(id);
    }
}
