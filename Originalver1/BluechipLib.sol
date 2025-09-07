// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

library BluechipLib {
    struct BluechipInfo {
        uint256 lastHarvestBlock;
        bool enrolled;
    }

    struct Storage {
        mapping(address => mapping(address => BluechipInfo)) bluechipWallets; // collection => wallet => info
        mapping(address => bool) isBluechipCollection; // collection flag
        mapping(address => bool) hasPaidFee;           // per-wallet (Option A)
        uint256 bluechipWalletFee;                     // uniform per-wallet fee
    }

    event BluechipEnrolled(address indexed wallet, uint256 feePaid);
    event BluechipHarvested(address indexed wallet, address indexed collection, uint256 reward);

    function enroll(
        Storage storage b,
        address /*collectionUnused*/,
        address wallet,
        uint256 currentBlock,
        uint256 fee,
        function(address,uint256) internal feeSplitter
    ) internal {
        if (!b.hasPaidFee[wallet]) {
            b.hasPaidFee[wallet] = true;
            if (fee > 0) feeSplitter(wallet, fee);
        }
        // mark enrolled for all future blue-chip collections (lazy map on first harvest)
        // we’ll set the per-collection enrollment lazily on first harvest call
        // but also seed a generic slot so governance weight can check quickly if needed
        b.bluechipWallets[address(0)][wallet] = BluechipInfo({ lastHarvestBlock: currentBlock, enrolled: true });
        emit BluechipEnrolled(wallet, fee);
    }

    function harvest(
        Storage storage b,
        address collection,
        address wallet,
        uint256 currentBlock,
        uint256 baseRewardRate,
        uint256 blocksPerUnit,
        function(address,uint256) internal rewardMinter
    ) internal {
        require(b.isBluechipCollection[collection], "not-bluechip");
        require(IERC721(collection).balanceOf(wallet) > 0, "no-hold");

        BluechipInfo storage info = b.bluechipWallets[collection][wallet];

        // if first time harvesting this collection, bootstrap from generic slot or now
        if (!info.enrolled) {
            uint256 start = b.bluechipWallets[address(0)][wallet].enrolled
                ? b.bluechipWallets[address(0)][wallet].lastHarvestBlock
                : currentBlock;
            info.lastHarvestBlock = start;
            info.enrolled = true;
        }

        uint256 blocksPassed = currentBlock - info.lastHarvestBlock;
        uint256 reward = (blocksPassed * baseRewardRate) / blocksPerUnit;
        if (reward > 0) {
            rewardMinter(wallet, reward);
            info.lastHarvestBlock = currentBlock;
            emit BluechipHarvested(wallet, collection, reward);
        }
    }
}
