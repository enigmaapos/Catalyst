// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TreasuryLib
/// @notice Minimal internal ledger for the protocol treasury (in CATA units).
/// @dev    The Core contract (which is also the ERC20 for CATA) holds the actual tokens.
///         This lib only tracks an internal balance and emits events. Transfers happen in Core.
library TreasuryLib {
    event TreasuryCredited(uint256 amount, uint256 newBalance);
    event TreasuryDebited(address indexed to, uint256 amount, uint256 newBalance);

    struct Storage {
        uint256 cataBalance; // tracked balance attributed to the treasury pool
    }

    /// @notice Credit treasury balance (e.g., from FeeManager split).
    function credit(Storage storage s, uint256 amount) internal {
        s.cataBalance += amount;
        emit TreasuryCredited(amount, s.cataBalance);
    }

    /// @notice Debit treasury balance (Core must actually transfer tokens out).
    function debit(Storage storage s, address to, uint256 amount) internal {
        require(amount <= s.cataBalance, "Treasury: insufficient");
        s.cataBalance -= amount;
        emit TreasuryDebited(to, amount, s.cataBalance);
    }

    function balanceOf(Storage storage s) internal view returns (uint256) {
        return s.cataBalance;
    }
}
