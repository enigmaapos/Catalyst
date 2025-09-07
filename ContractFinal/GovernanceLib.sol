// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library GovernanceLib {
    // Minimal governance (stake-count weight). Replace formula later if needed.

    error NotAdmin();
    error ProposalClosed();
    error AlreadyVoted();
    error InvalidQuorum();
    error NotProposer();
    error ExecOnlyOnce();

    struct Storage {
        address admin;          // governance admin (can be DEFAULT_ADMIN_ROLE)
        uint256 quorum;         // minimum total weight
        uint256 votingPeriod;   // blocks
        uint256 proposalCount;
        mapping(uint256 => Proposal) proposals;
        mapping(uint256 => mapping(address => bool)) voted;
    }

    struct Proposal {
        address proposer;
        bytes32 callKey;        // offchain key or onchain selector+args hash
        uint256 startBlock;
        uint256 endBlock;
        uint256 forWeight;
        uint256 againstWeight;
        bool executed;
    }

    event ProposalCreated(uint256 id, address proposer, bytes32 callKey, uint256 start, uint256 end);
    event Voted(uint256 id, address voter, bool support, uint256 weight);
    event Executed(uint256 id, bool passed);

    modifier onlyAdmin(Storage storage s, address caller){ if (caller!=s.admin) revert NotAdmin(); _; }

    function init(Storage storage s, address admin_) internal {
        s.admin = admin_;
        s.quorum = 100;         // default min weight
        s.votingPeriod = 40_000;
    }

    function setGovParams(Storage storage s, address caller, uint256 quorum_, uint256 period_) internal onlyAdmin(s,caller) {
        if (quorum_ == 0 || period_ == 0) revert InvalidQuorum();
        s.quorum = quorum_;
        s.votingPeriod = period_;
    }

    function propose(Storage storage s, address proposer, bytes32 callKey) internal returns (uint256 id) {
        id = ++s.proposalCount;
        Proposal storage p = s.proposals[id];
        p.proposer = proposer;
        p.callKey = callKey;
        p.startBlock = block.number;
        p.endBlock = block.number + s.votingPeriod;
        emit ProposalCreated(id, proposer, callKey, p.startBlock, p.endBlock);
    }

    function vote(Storage storage s, uint256 id, address voter, uint256 weight, bool support) internal {
        Proposal storage p = s.proposals[id];
        if (block.number > p.endBlock) revert ProposalClosed();
        if (s.voted[id][voter]) revert AlreadyVoted();
        s.voted[id][voter] = true;
        if (support) p.forWeight += weight; else p.againstWeight += weight;
        emit Voted(id, voter, support, weight);
    }

    function canExecute(Storage storage s, uint256 id) internal view returns (bool passed) {
        Proposal storage p = s.proposals[id];
        if (p.executed) return false;
        if (block.number <= p.endBlock) return false;
        uint256 total = p.forWeight + p.againstWeight;
        if (total < s.quorum) return false;
        return p.forWeight > p.againstWeight;
    }

    function markExecuted(Storage storage s, uint256 id) internal {
        Proposal storage p = s.proposals[id];
        if (p.executed) revert ExecOnlyOnce();
        p.executed = true;
        emit Executed(id, true);
    }
}
