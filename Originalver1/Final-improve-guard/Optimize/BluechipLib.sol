// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Blue-chip staking helpers (wallet enrollment + per-collection bookkeeping).
library BluechipLib {
    // --- Errors (short names) ---
    error BC_AlreadyEnrolled();
    error BC_NotEnrolled();

    struct WalletEnrollment {
        bool enrolled;
        uint256 lastHarvestBlock;
    }

    struct Storage {
        // mapping: collection => (wallet => enrollment info)
        mapping(address => mapping(address => WalletEnrollment)) bluechipWallets;
        mapping(address => bool) isBluechipCollection;
        uint256 bluechipWalletFee;
    }

    /// @notice Enrolls a wallet (collection may be address(0) for global)
    /// @dev Calls feeHandler(wallet, fee) if fee > 0. Reverts only if already enrolled.
    function enroll(
        Storage storage b,
        address collection, // can be address(0) for global
        address wallet,
        uint256 blockNum,
        uint256 fee,
        function(address,uint256) internal feeHandler
    ) internal {
        WalletEnrollment storage we = b.bluechipWallets[collection][wallet];
        if (we.enrolled) revert BC_AlreadyEnrolled();

        if (fee > 0) {
            feeHandler(wallet, fee);
        }

        we.enrolled = true;
        we.lastHarvestBlock = blockNum;
    }

    /// @notice Harvest rewards for an enrolled wallet for a collection
    /// @dev If not enrolled, simply returns (no revert). This reduces revert overhead.
    function harvest(
        Storage storage b,
        address collection,
        address wallet,
        uint256 blockNum,
        uint256 baseRewardRate,
        uint256 blocksPerRewardUnit,
        function(address,uint256) internal mintReward
    ) internal {
        WalletEnrollment storage we = b.bluechipWallets[collection][wallet];
        if (!we.enrolled) return; // cheaper & friendlier than revert

        // compute reward (collapsed into single expression)
        uint256 reward = 0;
        unchecked {
            uint256 blocksElapsed = blockNum - we.lastHarvestBlock;
            reward = (blocksElapsed * baseRewardRate) / blocksPerRewardUnit;
        }

        if (reward > 0) {
            mintReward(wallet, reward);
        }

        we.lastHarvestBlock = blockNum;
    }
}
