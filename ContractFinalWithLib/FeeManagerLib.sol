// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FeeManagerLib
/// @notice Computes the immutable 90/9/1 split (burn/treasury/deployer)
/// @dev    Core is responsible for actually burning/transferring tokens and
///         updating the Treasury ledger. This lib stays pure/math-only.
library FeeManagerLib {
    // Denominator for all splits
    uint256 private constant DENOM = 10_000;

    // Immutable rule: 90% burn, 9% treasury, 1% deployer
    uint256 public constant BURN_BP     = 9000;
    uint256 public constant TREASURY_BP =  900;
    uint256 public constant DEPLOYER_BP =  100;

    event FeeSplitComputed(uint256 total, uint256 burnAmt, uint256 treasuryAmt, uint256 deployerAmt);

    /// @notice Compute the split amounts for a given total.
    function computeSplit(uint256 total) internal pure returns (uint256 burnAmt, uint256 treasuryAmt, uint256 deployerAmt) {
        burnAmt     = total * BURN_BP     / DENOM;
        treasuryAmt = total * TREASURY_BP / DENOM;
        deployerAmt = total - burnAmt - treasuryAmt; // avoid rounding dust
    }

    /// @notice Convenience wrapper that also emits an event.
    function computeAndEmit(uint256 total) internal returns (uint256 burnAmt, uint256 treasuryAmt, uint256 deployerAmt) {
        (burnAmt, treasuryAmt, deployerAmt) = computeSplit(total);
        emit FeeSplitComputed(total, burnAmt, treasuryAmt, deployerAmt);
    }
}
