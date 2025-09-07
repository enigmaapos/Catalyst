// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library FeeManagerLib {
    error ZeroAddress();
    error InsufficientBalance();

    struct Accounts {
        address cataToken;     // address of CATA ERC20
        address treasury;      // treasury receiver (9%)
        address deployerSink;  // deployer/owner receiver (1%)
    }

    // immutable policy in code: 90% burn, 9% treasury, 1% deployer
    uint256 internal constant BURN_BP     = 9000;
    uint256 internal constant TREASURY_BP = 900;
    uint256 internal constant DEPLOYER_BP = 100;
    uint256 internal constant BP_DENOM    = 10_000;

    event FeeSplit(uint256 total, uint256 burned, uint256 treasury, uint256 deployer);

    function splitFrom(address payer, Accounts storage a, IERC20Like t, uint256 amount) internal {
        if (a.cataToken == address(0) || a.treasury == address(0) || a.deployerSink == address(0)) revert ZeroAddress();
        if (amount == 0) return;

        uint256 burnAmt = amount * BURN_BP / BP_DENOM;
        uint256 treaAmt = amount * TREASURY_BP / BP_DENOM;
        uint256 depAmt  = amount - burnAmt - treaAmt;

        // transfer to this contract, then burn/forward
        if (!t.transferFrom(payer, address(this), amount)) revert InsufficientBalance();
        // burn
        t.burn(burnAmt);
        // forward
        if (!t.transfer(a.treasury, treaAmt)) revert InsufficientBalance();
        if (!t.transfer(a.deployerSink, depAmt)) revert InsufficientBalance();

        emit FeeSplit(amount, burnAmt, treaAmt, depAmt);
    }
}

interface IERC20Like {
    function transfer(address to, uint256 v) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
    function burn(uint256 v) external;
}
