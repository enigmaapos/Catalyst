// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Fee computation library — computes split portions by basis points.
/// @dev Storage held in main contract; this lib only contains math & setters/getters.
library FeeLib {
    struct Storage {
        uint16 burnBP;     // e.g., 9000 = 90.00%
        uint16 treasuryBP; // e.g., 900  = 9.00%
        uint16 deployerBP; // e.g., 100  = 1.00%
        // Keep as uint16 to save space; ensure sum <= 10000
    }

    event FeeBPUpdated(uint16 oldBurn, uint16 oldTreasury, uint16 oldDeployer, uint16 newBurn, uint16 newTreasury, uint16 newDeployer);

    function init(Storage storage f, uint16 burnBP_, uint16 treasuryBP_, uint16 deployerBP_) internal {
        require(uint256(burnBP_) + uint256(treasuryBP_) + uint256(deployerBP_) <= 10000, "FeeLib: bp sum>10000");
        f.burnBP = burnBP_;
        f.treasuryBP = treasuryBP_;
        f.deployerBP = deployerBP_;
    }

    function setBP(Storage storage f, uint16 burnBP_, uint16 treasuryBP_, uint16 deployerBP_) internal {
        require(uint256(burnBP_) + uint256(treasuryBP_) + uint256(deployerBP_) <= 10000, "FeeLib: bp sum>10000");
        uint16 ob = f.burnBP;
        uint16 ot = f.treasuryBP;
        uint16 od = f.deployerBP;
        f.burnBP = burnBP_;
        f.treasuryBP = treasuryBP_;
        f.deployerBP = deployerBP_;
        emit FeeBPUpdated(ob, ot, od, burnBP_, treasuryBP_, deployerBP_);
    }

    /// @notice Compute fee splits by basis points for a given amount.
    /// @return burnAmt, treasuryAmt, deployerAmt (sums to amount but rounding handled by deployerAmt = remainder)
    function computeSplits(Storage storage f, uint256 amount) internal view returns (uint256, uint256, uint256) {
        require(amount > 0, "FeeLib: zero amt");
        uint256 burnAmt = (amount * uint256(f.burnBP)) / 10000;
        uint256 treasuryAmt = (amount * uint256(f.treasuryBP)) / 10000;
        uint256 deployerAmt = amount - burnAmt - treasuryAmt;
        return (burnAmt, treasuryAmt, deployerAmt);
    }
}
