// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal burn-weighted governance primitives (compile-ready).
library GovernanceLib {
    // ---- Errors ----
    error AlreadyVoted();
    error VotingClosed();
    error VotingNotStarted();
    error NotProposer();
    error UnknownProposal();

    enum ProposalState { Pending, Active, Defeated, Succeeded, Executed, Canceled }

    struct Proposal {
        address proposer;
        uint64  startBlock;
        uint64  endBlock;
        uint128 forVotes;
        uint128 againstVotes;
        bool    executed;
        bool    canceled;
    }

    struct Storage {
        uint256 minBlocksVoting;
        uint256 quorum; // abstract units
        mapping(uint256 => Proposal) proposals;
        mapping(uint256 => mapping(address => bool)) hasVoted;
        uint256 proposalCount;
    }

    event ProposalCreated(uint256 indexed id, address indexed proposer, uint64 startBlock, uint64 endBlock);
    event VoteCast(address indexed voter, uint256 indexed id, bool support, uint128 weight);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCanceled(uint256 indexed id);

    function init(Storage storage s, uint256 minBlocks, uint256 quorum_) internal {
        s.minBlocksVoting = minBlocks;
        s.quorum = quorum_;
    }

    function propose(Storage storage s, address proposer) internal returns (uint256 id) {
        id = ++s.proposalCount;
        uint64 start = uint64(block.number);
        uint64 end   = uint64(block.number + s.minBlocksVoting);
        s.proposals[id] = Proposal({
            proposer: proposer,
            startBlock: start,
            endBlock: end,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            canceled: false
        });
        emit ProposalCreated(id, proposer, start, end);
    }

    function castVote(Storage storage s, uint256 id, address voter, bool support, uint128 weight) internal {
        Proposal storage p = s.proposals[id];
        if (p.proposer == address(0)) revert UnknownProposal();
        if (block.number < p.startBlock) revert VotingNotStarted();
        if (block.number > p.endBlock) revert VotingClosed();
        if (s.hasVoted[id][voter]) revert AlreadyVoted();

        s.hasVoted[id][voter] = true;
        if (support) p.forVotes += weight;
        else p.againstVotes += weight;

        emit VoteCast(voter, id, support, weight);
    }

    function state(Storage storage s, uint256 id) internal view returns (ProposalState) {
        Proposal storage p = s.proposals[id];
        if (p.proposer == address(0)) return ProposalState.Canceled; // unknown treated as canceled
        if (p.canceled) return ProposalState.Canceled;
        if (p.executed) return ProposalState.Executed;
        if (block.number < p.startBlock) return ProposalState.Pending;
        if (block.number <= p.endBlock) return ProposalState.Active;
        // after voting
        if (p.forVotes + p.againstVotes < s.quorum || p.forVotes <= p.againstVotes) return ProposalState.Defeated;
        return ProposalState.Succeeded;
    }

    function execute(Storage storage s, uint256 id) internal {
        Proposal storage p = s.proposals[id];
        if (p.proposer == address(0)) revert UnknownProposal();
        require(state(s, id) == ProposalState.Succeeded, "GOV: not succeeded");
        p.executed = true;
        emit ProposalExecuted(id);
    }

    function cancel(Storage storage s, uint256 id, address caller) internal {
        Proposal storage p = s.proposals[id];
        if (p.proposer == address(0)) revert UnknownProposal();
        if (caller != p.proposer) revert NotProposer();
        require(!p.executed, "GOV: executed");
        p.canceled = true;
        emit ProposalCanceled(id);
    }
}
