// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GuardianLib
/// @notice Generic guardian council with compromise detection, last-honest reset, and owner reset.
/// @dev This is a library intended to be linked inside upgradeable/core contracts.
///      It coordinates *who can* trigger actions. The caller contract applies the actual side effects.

library GuardianLib {
    // ---------------------------- Types ----------------------------

    /// @notice Council identity (you can use one or more)
    enum CouncilId {
        DEPLOYER,  // Protects deployer / fee-receiver / DRS owner
        ADMIN,     // Protects DEFAULT_ADMIN_ROLE / upgrade admin
        SHARED     // Single council shared for both domains (if used, you typically ignore the others)
    }

    /// @notice Compact council configuration & state
    struct Council {
        // Set of guardians
        address[] guardians;
        mapping(address => bool) isGuardian;

        // Voting / approval parameters
        uint8 threshold;  // e.g., 5 for 5-of-7
        uint8 size;       // guardians.length cached

        // Active proposal (one at a time)
        bytes32 activeProposalId; // keccak256(abi.encode(councilId, proposedAccount, nonce, timestamp))
        address proposedAccount;  // the candidate account to recover/assign
        uint64 proposedAt;        // timestamp of proposal start
        uint8 approvals;          // current count of approvals
        mapping(address => bool) approved; // who approved

        // Compromise / lock logic
        bool locked;              // true when N-of-N approvals happened (suspected full compromise)
        address lastHonest;       // the only guardian who didn't approve at N-1 approvals
        uint64 lastHonestDeadline;// deadline for last-honest reset

        // Monotonic nonce to ensure unique ids and mitigate replay across resets
        uint64 proposalNonce;
    }

    /// @notice Library storage grouping multiple councils
    struct Storage {
        mapping(uint8 => Council) councils; // councilId => Council
        uint64 lastHonestWindow;            // e.g., 48h in seconds
        uint64 proposalTTL;                 // e.g., 3 days in seconds
        bool initialized;
    }

    // ---------------------------- Events ----------------------------

    event CouncilInitialized(uint8 indexed councilId, uint8 size, uint8 threshold);
    event GuardiansReset(uint8 indexed councilId, address[] newGuardians);
    event GuardianAdded(uint8 indexed councilId, address guardian);
    event GuardianRemoved(uint8 indexed councilId, address guardian);

    event RecoveryProposed(uint8 indexed councilId, bytes32 proposalId, address proposedAccount, uint64 proposedAt);
    event RecoveryApproved(uint8 indexed councilId, bytes32 proposalId, address by, uint8 approvals, bool warning, bool locked);
    event RecoveryRevoked(uint8 indexed councilId, bytes32 proposalId, address by, uint8 approvals);
    event RecoveryExecuted(uint8 indexed councilId, bytes32 proposalId, address newAccount);
    event CouncilLocked(uint8 indexed councilId, bytes32 proposalId);
    event LastHonestActivated(uint8 indexed councilId, address lastHonest, uint64 deadline);
    event LastHonestReset(uint8 indexed councilId, address by, address[] newGuardians);

    // ---------------------------- Errors (custom, gas-lean) ----------------------------

    error AlreadyInitialized();
    error InvalidParams();
    error InvalidGuardians();
    error DuplicateGuardian();
    error NotGuardian();
    error AlreadyApproved();
    error NoActiveProposal();
    error ActiveProposalExists();
    error ProposalExpired();
    error ThresholdNotMet();
    error Locked();
    error NotLastHonest();
    error WindowExpired();
    error NotAllowed();
    error NothingToDo();

    // ---------------------------- Constants ----------------------------

    uint8 internal constant MAX_GUARDIANS = 15; // keep bounded to avoid heavy loops

    // ---------------------------- Helpers ----------------------------

    function _c(Storage storage s, uint8 councilId) private view returns (Council storage) {
        return s.councils[councilId];
    }

    function _isGuardian(Council storage c, address a) private view returns (bool) {
        return c.isGuardian[a];
    }

    function _clearApprovals(Council storage c) private {
        // NOTE: We do not iterate to clear mapping (approved); mappings are sparse.
        // The new proposalId semantically invalidates old approvals.
        c.approvals = 0;
    }

    // ---------------------------- Init / Reset ----------------------------

    /// @notice Initialize all councils + global windows/TTLs once.
    function init(
        Storage storage s,
        address[] calldata deployerGuardians,
        uint8 deployerThreshold,
        address[] calldata adminGuardians,
        uint8 adminThreshold,
        address[] calldata sharedGuardians,
        uint8 sharedThreshold,
        uint64 proposalTTLSeconds,
        uint64 lastHonestWindowSeconds
    ) internal {
        if (s.initialized) revert AlreadyInitialized();
        if (proposalTTLSeconds == 0 || lastHonestWindowSeconds == 0) revert InvalidParams();

        _initCouncil(_c(s, uint8(CouncilId.DEPLOYER)), deployerGuardians, deployerThreshold, uint8(CouncilId.DEPLOYER));
        _initCouncil(_c(s, uint8(CouncilId.ADMIN)), adminGuardians, adminThreshold, uint8(CouncilId.ADMIN));
        _initCouncil(_c(s, uint8(CouncilId.SHARED)), sharedGuardians, sharedThreshold, uint8(CouncilId.SHARED));

        s.proposalTTL = proposalTTLSeconds;
        s.lastHonestWindow = lastHonestWindowSeconds;
        s.initialized = true;
    }

    function _initCouncil(
        Council storage c,
        address[] calldata guardians,
        uint8 threshold,
        uint8 councilId
    ) private {
        uint256 n = guardians.length;
        if (n == 0) return; // allow unused council
        if (n > MAX_GUARDIANS || threshold == 0 || threshold > n) revert InvalidParams();

        c.size = uint8(n);
        c.threshold = threshold;

        for (uint256 i = 0; i < n; ++i) {
            address g = guardians[i];
            if (g == address(0)) revert InvalidGuardians();
            if (c.isGuardian[g]) revert DuplicateGuardian();
            c.isGuardian[g] = true;
        }
        c.guardians = guardians;

        emit CouncilInitialized(councilId, c.size, c.threshold);
    }

    /// @notice Owner or valid protected account may reset the whole guardian set.
    /// @dev Side-effect authorization must be enforced by caller contract.
    function ownerResetGuardians(
        Storage storage s,
        uint8 councilId,
        address[] calldata newGuardians,
        uint8 newThreshold
    ) internal {
        Council storage c = _c(s, councilId);
        if (newGuardians.length == 0 || newGuardians.length > MAX_GUARDIANS) revert InvalidParams();
        if (newThreshold == 0 || newThreshold > newGuardians.length) revert InvalidParams();

        // clear membership
        for (uint256 i = 0; i < c.guardians.length; ++i) {
            c.isGuardian[c.guardians[i]] = false;
        }

        // set new
        delete c.guardians;
        c.guardians = newGuardians;
        c.size = uint8(newGuardians.length);
        c.threshold = newThreshold;

        for (uint256 j = 0; j < newGuardians.length; ++j) {
            address g = newGuardians[j];
            if (g == address(0)) revert InvalidGuardians();
            if (c.isGuardian[g]) revert DuplicateGuardian();
            c.isGuardian[g] = true;
        }

        // wipe active proposal and approvals
        c.activeProposalId = bytes32(0);
        c.proposedAccount = address(0);
        c.proposedAt = 0;
        _clearApprovals(c);
        c.locked = false;
        c.lastHonest = address(0);
        c.lastHonestDeadline = 0;
        c.proposalNonce++;

        emit GuardiansReset(councilId, newGuardians);
    }

    /// @notice Add/remove single guardian (owner-controlled). Clears active approvals but keeps proposal if same candidate.
    function ownerAddGuardian(
        Storage storage s, uint8 councilId, address guardian
    ) internal {
        Council storage c = _c(s, councilId);
        if (guardian == address(0)) revert InvalidGuardians();
        if (c.size + 1 > MAX_GUARDIANS) revert InvalidParams();
        if (c.isGuardian[guardian]) revert DuplicateGuardian();

        c.isGuardian[guardian] = true;
        c.guardians.push(guardian);
        c.size++;

        // approvals reset
        _clearApprovals(c);
        for (uint256 i = 0; i < c.guardians.length; ++i) {
            // no-op loop used purely to keep symmetry if you later add per-guardian approval caches.
        }

        emit GuardianAdded(councilId, guardian);
    }

    function ownerRemoveGuardian(
        Storage storage s, uint8 councilId, address guardian
    ) internal {
        Council storage c = _c(s, councilId);
        if (!_isGuardian(c, guardian)) revert NotGuardian();

        c.isGuardian[guardian] = false;

        // compact array
        address[] storage arr = c.guardians;
        for (uint256 i = 0; i < arr.length; ++i) {
            if (arr[i] == guardian) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
        c.size = uint8(arr.length);

        // approvals reset
        _clearApprovals(c);

        emit GuardianRemoved(councilId, guardian);
    }

    // ---------------------------- Propose / Approve / Revoke ----------------------------

    /// @notice Start a recovery to assign `proposedAccount` for the given council.
    /// @dev Anyone can *call* this if you allow it, but the caller contract should restrict it to guardians.
    function propose(
        Storage storage s,
        uint8 councilId,
        address proposer,
        address proposedAccount
    ) internal returns (bytes32 proposalId) {
        Council storage c = _c(s, councilId);
        if (!_isGuardian(c, proposer)) revert NotGuardian();
        if (c.locked) revert Locked();
        if (proposedAccount == address(0)) revert InvalidParams();
        if (c.activeProposalId != bytes32(0)) revert ActiveProposalExists();

        c.proposalNonce++;
        proposalId = keccak256(abi.encode(councilId, proposedAccount, c.proposalNonce, block.timestamp));
        c.activeProposalId = proposalId;
        c.proposedAccount = proposedAccount;
        c.proposedAt = uint64(block.timestamp);

        // reset approvals mapping by changing proposalId context; count is set to 0
        _clearApprovals(c);

        emit RecoveryProposed(councilId, proposalId, proposedAccount, c.proposedAt);
    }

    /// @notice Guardian approves the active proposal.
    function approve(
        Storage storage s,
        uint8 councilId,
        address guardian
    ) internal returns (bool warning, bool lockedNow, uint8 approvals) {
        Council storage c = _c(s, councilId);
        if (!_isGuardian(c, guardian)) revert NotGuardian();
        if (c.locked) revert Locked();
        if (c.activeProposalId == bytes32(0)) revert NoActiveProposal();
        if (block.timestamp > c.proposedAt + s.proposalTTL) revert ProposalExpired();
        if (c.approved[guardian]) revert AlreadyApproved();

        c.approved[guardian] = true;
        approvals = ++c.approvals;

        // If approvals == size - 1, identify last-honest and open window
        if (approvals == c.size - 1) {
            // find the only guardian who hasn't approved
            address lh = address(0);
            uint256 miss = 0;
            for (uint256 i = 0; i < c.guardians.length; ++i) {
                address g = c.guardians[i];
                if (!c.approved[g]) {
                    lh = g;
                    miss++;
                }
            }
            // Must be exactly one guardian missing
            if (miss == 1) {
                c.lastHonest = lh;
                c.lastHonestDeadline = uint64(block.timestamp) + s.lastHonestWindow;
                warning = true;
                emit LastHonestActivated(councilId, lh, c.lastHonestDeadline);
            }
        }

        // If approvals == size (N-of-N), lock the council (suspected compromise)
        if (approvals == c.size) {
            c.locked = true;
            lockedNow = true;
            emit CouncilLocked(councilId, c.activeProposalId);
        }

        emit RecoveryApproved(councilId, c.activeProposalId, guardian, approvals, warning, lockedNow);
    }

    /// @notice Guardian revokes their approval before execution/lock.
    function revoke(Storage storage s, uint8 councilId, address guardian) internal returns (uint8 approvals) {
        Council storage c = _c(s, councilId);
        if (!_isGuardian(c, guardian)) revert NotGuardian();
        if (c.locked) revert Locked();
        if (c.activeProposalId == bytes32(0)) revert NoActiveProposal();
        if (block.timestamp > c.proposedAt + s.proposalTTL) revert ProposalExpired();
        if (!c.approved[guardian]) revert NothingToDo();

        c.approved[guardian] = false;
        approvals = --c.approvals;

        // Reset last-honest window if we step away from N-1 state
        if (c.lastHonest != address(0) && approvals < c.size - 1) {
            c.lastHonest = address(0);
            c.lastHonestDeadline = 0;
        }

        emit RecoveryRevoked(councilId, c.activeProposalId, guardian, approvals);
    }

    // ---------------------------- Execute / Reset ----------------------------

    /// @notice Execute the recovery if threshold met; returns the chosen account and proposalId.
    /// @dev Caller must enforce that only the protocol can call this and apply side effects.
    function execute(
        Storage storage s,
        uint8 councilId
    ) internal returns (bytes32 proposalId, address newAccount) {
        Council storage c = _c(s, councilId);
        if (c.locked) revert Locked();
        if (c.activeProposalId == bytes32(0)) revert NoActiveProposal();
        if (block.timestamp > c.proposedAt + s.proposalTTL) revert ProposalExpired();
        if (c.approvals < c.threshold) revert ThresholdNotMet();

        proposalId = c.activeProposalId;
        newAccount = c.proposedAccount;

        // Clear proposal context (new proposal = fresh approvals)
        c.activeProposalId = bytes32(0);
        c.proposedAccount = address(0);
        c.proposedAt = 0;
        _clearApprovals(c);
        c.lastHonest = address(0);
        c.lastHonestDeadline = 0;

        emit RecoveryExecuted(councilId, proposalId, newAccount);
    }

    /// @notice Last-honest guardian may reset guardians during the special window (when approvals == size-1).
    /// @dev Caller should ensure only council-specific admin invokes this function (we check guardian identity here).
    function lastHonestResetGuardians(
        Storage storage s,
        uint8 councilId,
        address caller,
        address[] calldata newGuardians,
        uint8 newThreshold
    ) internal {
        Council storage c = _c(s, councilId);
        if (caller != c.lastHonest) revert NotLastHonest();
        if (c.lastHonest == address(0) || c.lastHonestDeadline == 0) revert NotAllowed();
        if (block.timestamp > c.lastHonestDeadline) revert WindowExpired();
        if (c.approvals != c.size - 1) revert NotAllowed(); // only valid at N-1 approvals

        // Perform the reset
        ownerResetGuardians(s, councilId, newGuardians, newThreshold);

        // Consume the last-honest window
        c.lastHonest = address(0);
        c.lastHonestDeadline = 0;

        emit LastHonestReset(councilId, caller, newGuardians);
    }

    // ---------------------------- Views ----------------------------

    /// @notice Readable snapshot for UIs.
    struct CouncilView {
        uint8 size;
        uint8 threshold;
        bool locked;
        bytes32 activeProposalId;
        address proposedAccount;
        uint64 proposedAt;
        uint8 approvals;
        address lastHonest;
        uint64 lastHonestDeadline;
        address[] guardians;
    }

    function viewCouncil(Storage storage s, uint8 councilId) internal view returns (CouncilView memory v) {
        Council storage c = _c(s, councilId);
        v.size = c.size;
        v.threshold = c.threshold;
        v.locked = c.locked;
        v.activeProposalId = c.activeProposalId;
        v.proposedAccount = c.proposedAccount;
        v.proposedAt = c.proposedAt;
        v.approvals = c.approvals;
        v.lastHonest = c.lastHonest;
        v.lastHonestDeadline = c.lastHonestDeadline;
        v.guardians = c.guardians;
    }

    function hasApproved(Storage storage s, uint8 councilId, address guardian) internal view returns (bool) {
        Council storage c = _c(s, councilId);
        return c.approved[guardian];
    }

    function isGuardian(Storage storage s, uint8 councilId, address who) internal view returns (bool) {
        Council storage c = _c(s, councilId);
        return c.isGuardian[who];
    }
}
