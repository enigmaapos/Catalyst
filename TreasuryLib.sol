// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Simple treasury bookkeeping helpers as a library.
/// @dev Main contract performs token transfers; this updates internal accounting.
library TreasuryLib {
    struct Storage {
        uint256 balance; // token amount accounted to treasury
        // Optionally: mapping(address=>uint256) depositsBy; // if you want per-sender tracking
    }

    event TreasuryRecordedDeposit(address indexed from, uint256 amount, uint256 newBalance);
    event TreasuryRecordedWithdrawal(address indexed to, uint256 amount, uint256 newBalance);

    function recordDeposit(Storage storage t, address from, uint256 amount) internal {
        require(amount > 0, "TreasuryLib: zero");
        t.balance += amount;
        emit TreasuryRecordedDeposit(from, amount, t.balance);
    }

    function recordWithdrawal(Storage storage t, address to, uint256 amount) internal {
        require(amount > 0, "TreasuryLib: zero");
        require(t.balance >= amount, "TreasuryLib: insuf");
        t.balance -= amount;
        emit TreasuryRecordedWithdrawal(to, amount, t.balance);
    }

    function balanceOf(Storage storage t) internal view returns (uint256) {
        return t.balance;
    }
}
