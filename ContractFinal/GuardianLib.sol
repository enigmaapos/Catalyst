// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library GuardianLib {
    error NotGuardian();
    error AlreadyGuardian();
    error InvalidGuardianCount();
    error ThresholdTooHigh();
    error NotDeployer();
    error Locked();
    error AlreadyApproved();
    error NoProposal();
    error NotEligible();
    error WindowElapsed();
    error OnlyLastHonest();
    error ZeroAddress();

    struct Council {
        // council members
        address[7] members;       // fixed length; unused tail = address(0)
        uint8     size;           // 1..7
        uint8     threshold;      // e.g., 5
        // recovery proposal
        address proposedNew;      // candidate address (deployer/admin)
        uint8     approvals;      // how many unique approvals
        bool      locked;         // true when approvals == size (full sign → suspected compromise)
        // approvals map
        mapping(address => bool) approved;
        // last honest guardian window
        uint256   lastHonestStartBlock;
        address   lastHonest;     // the only guardian who has not approved when approvals == size-1
        uint256   lastHonestWindow; // configured from registry
    }

    event GuardianAdded(address indexed g);
    event GuardianRemoved(address indexed g);
    event ThresholdChanged(uint8 t);
    event Proposed(address indexed candidate);
    event Approved(address indexed g, uint8 approvals);
    event LockedCouncil();
    event ResetByDeployer(address[7] newSet, uint8 size, uint8 threshold);
    event ResetByLastHonest(address[7] newSet, uint8 size, uint8 threshold, address lastHonest);

    // ---- Admin ops
    function initCouncil(Council storage c, address[] memory initial, uint8 threshold_, uint256 lastHonestWindow_) internal {
        if (initial.length == 0 || initial.length > 7) revert InvalidGuardianCount();
        if (threshold_ == 0 || threshold_ > initial.length) revert ThresholdTooHigh();
        c.size = uint8(initial.length);
        c.threshold = threshold_;
        c.lastHonestWindow = lastHonestWindow_;
        for (uint i=0;i<initial.length;i++){
            c.members[i]=initial[i];
            emit GuardianAdded(initial[i]);
        }
        emit ThresholdChanged(threshold_);
    }

    function isGuardian(Council storage c, address a) internal view returns (bool) {
        for (uint i=0;i<c.size;i++){ if (c.members[i]==a) return true; }
        return false;
    }

    function addGuardian(Council storage c, address a) internal {
        if (a==address(0)) revert ZeroAddress();
        if (isGuardian(c,a)) revert AlreadyGuardian();
        if (c.size==7) revert InvalidGuardianCount();
        c.members[c.size++] = a;
        emit GuardianAdded(a);
        if (c.threshold>c.size) c.threshold=c.size; // keep safe
    }

    function removeGuardian(Council storage c, address a) internal {
        bool found;
        for (uint i=0;i<c.size;i++){
            if (c.members[i]==a){
                c.members[i]=c.members[c.size-1];
                c.members[c.size-1]=address(0);
                c.size--;
                found=true;
                emit GuardianRemoved(a);
                break;
            }
        }
        if (!found) revert NotGuardian();
        if (c.threshold>c.size) c.threshold=c.size;
    }

    function setThreshold(Council storage c, uint8 t) internal {
        if (t==0 || t>c.size) revert ThresholdTooHigh();
        c.threshold=t;
        emit ThresholdChanged(t);
    }

    // ---- Recovery flow
    function propose(Council storage c, address guardian, address candidate) internal {
        if (!isGuardian(c, guardian)) revert NotGuardian();
        c.proposedNew = candidate;
        c.approvals = 0;
        c.locked = false;
        // reset approvals mapping
        for (uint i=0;i<c.size;i++){ c.approved[c.members[i]] = false; }
        c.lastHonest = address(0);
        c.lastHonestStartBlock = 0;
        emit Proposed(candidate);
    }

    function approve(Council storage c, address guardian) internal returns (bool reachedThreshold, bool lockedNow) {
        if (!isGuardian(c, guardian)) revert NotGuardian();
        if (c.proposedNew == address(0)) revert NoProposal();
        if (c.locked) revert Locked();
        if (c.approved[guardian]) revert AlreadyApproved();

        c.approved[guardian]=true;
        c.approvals += 1;
        emit Approved(guardian, c.approvals);

        // set last honest when approvals == size-1
        if (c.approvals == c.size-1) {
            // compute last honest
            address lh = address(0);
            for (uint i=0;i<c.size;i++){
                address m = c.members[i];
                if (!c.approved[m]) { lh = m; break; }
            }
            c.lastHonest = lh;
            c.lastHonestStartBlock = block.number;
        }

        // lock if full approvals
        if (c.approvals == c.size) {
            c.locked = true;
            emit LockedCouncil();
            lockedNow = true;
        }

        reachedThreshold = (c.approvals >= c.threshold);
    }

    function resetByDeployer(Council storage c, address caller, address deployer, address[] memory newSet, uint8 newThreshold) internal {
        if (caller != deployer) revert NotDeployer();
        _reset(c, newSet, newThreshold);
        emit ResetByDeployer(_pack7(c), c.size, c.threshold);
    }

    function resetByLastHonest(Council storage c, address caller, address[] memory newSet, uint8 newThreshold) internal {
        if (caller != c.lastHonest) revert OnlyLastHonest();
        if (c.lastHonest == address(0)) revert NotEligible();
        if (block.number > c.lastHonestStartBlock + c.lastHonestWindow) revert WindowElapsed();
        _reset(c, newSet, newThreshold);
        emit ResetByLastHonest(_pack7(c), c.size, c.threshold, caller);
    }

    function _reset(Council storage c, address[] memory newSet, uint8 newThreshold) private {
        if (newSet.length==0 || newSet.length>7) revert InvalidGuardianCount();
        if (newThreshold==0 || newThreshold>newSet.length) revert ThresholdTooHigh();
        // clear
        for (uint i=0;i<c.size;i++){ c.members[i]=address(0); }
        c.size = uint8(newSet.length);
        for (uint i=0;i<newSet.length;i++){ c.members[i]=newSet[i]; }
        c.threshold = newThreshold;
        // clear approvals & proposal & lock
        c.proposedNew = address(0);
        c.approvals = 0;
        c.locked = false;
        for (uint i=0;i<c.size;i++){ c.approved[c.members[i]]=false; }
        c.lastHonest = address(0);
        c.lastHonestStartBlock = 0;
    }

    function _pack7(Council storage c) private view returns (address[7] memory out) {
        for (uint i=0;i<7;i++){ out[i]=c.members[i]; }
    }
}
