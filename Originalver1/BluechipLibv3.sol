// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Blue-chip staking helpers (wallet enrollment + per-collection bookkeeping).
library BluechipLib {
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

    event WalletEnrolled(address indexed wallet, address indexed collection);
    event WalletHarvested(address indexed wallet, address indexed collection, uint256 reward);

    function init(Storage storage b, uint256 fee) external {
        b.bluechipWalletFee = fee;
    }

    function register(Storage storage b, address collection) external {
        b.isBluechipCollection[collection] = true;
    }

    function enroll(
        Storage storage b,
        address collection, // can be address(0) for global
        address wallet,
        uint256 blockNum,
        uint256 fee,
        function(address,uint256) external feeHandler
    ) external {
        WalletEnrollment storage we = b.bluechipWallets[collection][wallet];
        require(!we.enrolled, "Already enrolled");

        if (fee > 0) {
            feeHandler(wallet, fee);
        }

        we.enrolled = true;
        we.lastHarvestBlock = blockNum;
        emit WalletEnrolled(wallet, collection);
    }

    function harvest(
        Storage storage b,
        address collection,
        address wallet,
        uint256 blockNum,
        uint256 baseRewardRate,
        uint256 blocksPerRewardUnit,
        function(address,uint256) external mintReward
    ) external {
        WalletEnrollment storage we = b.bluechipWallets[collection][wallet];
        require(we.enrolled, "Not enrolled");

        // Example reward logic
        uint256 blocksElapsed = blockNum - we.lastHarvestBlock;
        uint256 reward = (blocksElapsed * baseRewardRate) / blocksPerRewardUnit;

        if (reward > 0) {
            mintReward(wallet, reward);
        }

        we.lastHarvestBlock = blockNum;
        emit WalletHarvested(wallet, collection, reward);
    }
}
