// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernanceLib} from "./GovernanceLib.sol";

/// @title ProposalExecutorLib
/// @notice Minimal, generic executor that:
///         1) Ensures a proposal is executable (passed + within grace window)
///         2) Verifies actionsHash integrity
///         3) Delegates concrete state changes to the upgradeable core via hooks
/// @dev  All privileged mutations must be implemented by the Core (UUPS),
///       not inside this library. The Core enforces access control and invariants.
library ProposalExecutorLib {
    // ============== ERRORS ==============
    error InvalidActionsHash();
    error EmptyActions();
    error UpgradeZeroAddress();
    error LengthMismatch();

    // ============== HOOKS INTERFACE ==============
    /// @notice The upgradeable Core must implement this set of callbacks.
    /// @dev     Libraries call the Core through this interface to make changes.
    interface IExecutorHooks {
        // ---- Config: generic key/value updates (e.g., fees, caps, durations)
        function execConfigUpdates(bytes32[] calldata keys, uint256[] calldata values) external;

        // ---- Collections & Tiers
        // 0 = UNVERIFIED, 1 = VERIFIED
        function execSetCollectionTier(address collection, uint8 tier) external;

        // ---- Blue-chip registration (non-custodial yield path)
        function execSetBlueChipRegistration(address collection, bool enabled, uint256 declaredSupply) external;

        // ---- Treasury
        function execTreasuryTransfer(address to, uint256 amount) external;

        // ---- UUPS upgrade
        function execUpgradeTo(address newImplementation) external;

        // ---- Guardians passthrough (GCSS / AGC)
        // op: arbitrary operation code the Core understands (e.g., add/remove/reset)
        // data: abi-encoded parameters for that operation
        function execGuardianOp(uint8 op, bytes calldata data) external;
    }

    // ============== ACTION TYPES ==============
    struct ConfigUpdate {
        bytes32 key;
        uint256 value;
    }

    struct TreasuryTransfer {
        address to;
        uint256 amount;
    }

    struct GuardianOp {
        uint8 op;        // Core-defined opcode
        bytes params;    // Core-defined abi-encoded payload
    }

    /// @notice A bundle of actions the proposal intends to execute.
    /// @dev     The exact same encoding must be used to build actionsHash at propose-time:
    ///          keccak256(abi.encode(actions))
    struct Actions {
        // 1) config updates
        ConfigUpdate[] configUpdates;

        // 2) collection tier changes
        address[] promoteToVerified;   // set tier = 1
        address[] demoteToUnverified;  // set tier = 0

        // 3) blue-chip registration updates
        address[] blueChipEnable;      // enable blue-chip mode
        address[] blueChipDisable;     // disable blue-chip mode
        uint256[] blueChipDeclaredSupplyForEnable; // must match blueChipEnable length

        // 4) treasury transfers
        TreasuryTransfer[] transfers;

        // 5) upgrade (optional)
        address newImplementation;     // zero means "no upgrade"

        // 6) guardian operations passthrough (GCSS / AGC)
        GuardianOp[] guardianOps;
    }

    // ============== EVENTS ==============
    event ProposalActionsExecuted(uint256 indexed id, bytes32 actionsHash);

    // ============== EXECUTION ==============
    /// @notice Validates and executes a proposal's Actions by invoking Core hooks.
    /// @param gs Governance storage (from Core)
    /// @param proposalId The id of the proposal to execute
    /// @param totalWeightSupply Voting supply snapshot used when determining state
    /// @param actions The decoded, structured actions bundle
    /// @param hooks Target address that implements IExecutorHooks (usually address(this) Core)
    function execute(
        GovernanceLib.Storage storage gs,
        uint256 proposalId,
        uint256 totalWeightSupply,
        Actions calldata actions,
        address hooks
    ) internal {
        // 1) Ensure proposal is in Executable state and passed
        GovernanceLib.Proposal memory p = gs.getProposal(proposalId);
        {
            // Ensure still executable
            GovernanceLib.ProposalState st = GovernanceLib.state(gs, proposalId, totalWeightSupply);
            // Only Executable is acceptable; core may also allow Expired -> revert safely
            if (st != GovernanceLib.ProposalState.Executable) revert GovernanceLib.NotSucceeded();
        }

        // 2) Check actionsHash integrity
        bytes32 hashNow = keccak256(abi.encode(actions));
        if (hashNow != p.actionsHash) revert InvalidActionsHash();

        // 3) Ensure bundle is not entirely empty (optional guard)
        bool hasWork =
            actions.configUpdates.length > 0 ||
            actions.promoteToVerified.length > 0 ||
            actions.demoteToUnverified.length > 0 ||
            actions.blueChipEnable.length > 0 ||
            actions.blueChipDisable.length > 0 ||
            actions.transfers.length > 0 ||
            actions.newImplementation != address(0) ||
            actions.guardianOps.length > 0;

        if (!hasWork) revert EmptyActions();

        IExecutorHooks H = IExecutorHooks(hooks);

        // ========== 3a) CONFIG UPDATES ==========
        if (actions.configUpdates.length > 0) {
            bytes32[] memory keys = new bytes32[](actions.configUpdates.length);
            uint256[] memory values = new uint256[](actions.configUpdates.length);
            for (uint256 i = 0; i < actions.configUpdates.length; i++) {
                keys[i] = actions.configUpdates[i].key;
                values[i] = actions.configUpdates[i].value;
            }
            H.execConfigUpdates(keys, values);
        }

        // ========== 3b) COLLECTION TIER CHANGES ==========
        for (uint256 i = 0; i < actions.promoteToVerified.length; i++) {
            H.execSetCollectionTier(actions.promoteToVerified[i], 1);
        }
        for (uint256 i = 0; i < actions.demoteToUnverified.length; i++) {
            H.execSetCollectionTier(actions.demoteToUnverified[i], 0);
        }

        // ========== 3c) BLUE-CHIP REGISTRATION ==========
        if (actions.blueChipEnable.length != actions.blueChipDeclaredSupplyForEnable.length) {
            revert LengthMismatch();
        }
        for (uint256 i = 0; i < actions.blueChipEnable.length; i++) {
            H.execSetBlueChipRegistration(
                actions.blueChipEnable[i],
                true,
                actions.blueChipDeclaredSupplyForEnable[i]
            );
        }
        for (uint256 i = 0; i < actions.blueChipDisable.length; i++) {
            // declaredSupply ignored when disabling
            H.execSetBlueChipRegistration(actions.blueChipDisable[i], false, 0);
        }

        // ========== 3d) TREASURY TRANSFERS ==========
        for (uint256 i = 0; i < actions.transfers.length; i++) {
            H.execTreasuryTransfer(actions.transfers[i].to, actions.transfers[i].amount);
        }

        // ========== 3e) UUPS UPGRADE ==========
        if (actions.newImplementation != address(0)) {
            // tiny safety guard here; Core will also guard and restrict caller
            if (actions.newImplementation == address(0)) revert UpgradeZeroAddress();
            H.execUpgradeTo(actions.newImplementation);
        }

        // ========== 3f) GUARDIAN OPERATIONS (GCSS/AGC) ==========
        for (uint256 i = 0; i < actions.guardianOps.length; i++) {
            H.execGuardianOp(actions.guardianOps[i].op, actions.guardianOps[i].params);
        }

        // 4) Mark executed in Governance storage (emits event)
        GovernanceLib.markExecuted(gs, proposalId, totalWeightSupply);
        emit ProposalActionsExecuted(proposalId, p.actionsHash);
    }
}
