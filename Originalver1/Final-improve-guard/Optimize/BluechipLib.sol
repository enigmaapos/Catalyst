// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Blue-chip staking helpers.
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
        address[] collections; // Array to track bluechip collections
        mapping(address => uint256) collectionIndex; // Maps collection address to its index in the array
    }

    // Custom errors used in this library
    error ZeroAddress();
    error NotRegistered();
    error AlreadyExists();
    error AlreadyBluechip();
    error NotBluechip();

    event BluechipAdded(address indexed collection, uint256 count);
    event BluechipRemoved(address indexed collection, uint256 count);

    function addBluechip(
        Storage storage b,
        address _collection,
        bool _registered
    ) internal {
        if (_collection == address(0)) { revert ZeroAddress(); }
        if (!_registered) { revert NotRegistered(); }
        if (b.isBluechipCollection[_collection]) { revert AlreadyBluechip(); }

        b.isBluechipCollection[_collection] = true;
        b.collections.push(_collection);
        b.collectionIndex[_collection] = b.collections.length - 1;

        emit BluechipAdded(_collection, b.collections.length);
    }

    function removeBluechip(
        Storage storage b,
        address _collection
    ) internal {
        if (_collection == address(0)) { revert ZeroAddress(); }
        if (!b.isBluechipCollection[_collection]) { revert NotBluechip(); }
        
        b.isBluechipCollection[_collection] = false;

        uint256 index = b.collectionIndex[_collection];
        uint256 lastIndex = b.collections.length - 1;
        address lastCollection = b.collections[lastIndex];

        if (index != lastIndex) {
            b.collections[index] = lastCollection;
            b.collectionIndex[lastCollection] = index;
        }
        b.collections.pop();
        delete b.collectionIndex[_collection];

        emit BluechipRemoved(_collection, b.collections.length);
    }

    function isWalletEnrolled(Storage storage b, address collection, address wallet) internal view returns (bool) {
        return b.bluechipWallets[collection][wallet].enrolled;
    }
    
    function enroll(
        Storage storage b,
        address collection, // can be address(0) for global
        address wallet,
        uint256 blockNum,
        uint256 fee,
        function(address,uint256) internal feeHandler
    ) internal {
        WalletEnrollment storage we = b.bluechipWallets[collection][wallet];
        if (we.enrolled) { revert AlreadyExists(); }

        if (fee > 0) {
            feeHandler(wallet, fee);
        }

        we.enrolled = true;
        we.lastHarvestBlock = blockNum;
    }

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
        if (!we.enrolled) { revert NotStaked(); }

        uint256 blocksElapsed = blockNum - we.lastHarvestBlock;
        uint256 reward = (blocksElapsed * baseRewardRate) / blocksPerRewardUnit;

        if (reward > 0) {
            mintReward(wallet, reward);
            we.lastHarvestBlock = blockNum;
        }
    }
}
