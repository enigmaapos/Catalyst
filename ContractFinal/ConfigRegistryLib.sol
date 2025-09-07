// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ConfigRegistryLib {
    error NotAdmin();
    error InvalidParam();

    struct Storage {
        address admin;                // DEFAULT_ADMIN_ROLE holder (or admin governor)
        // staking economics
        uint256 baseRewardRate;       // scaled base rate
        uint256 blocksPerUnit;        // reward unit in blocks
        // caps
        uint256 perCollectionCap;     // default 20_000
        uint256 globalCap;            // default 1_000_000_000
        uint256 termCap;              // default 750_000_000
        uint256 permCap;              // default 250_000_000
        // fees
        uint256 harvestFee;           // flat CATA fee charged on harvest (subject to 90/9/1)
        uint256 unstakeFee;           // flat CATA fee charged on unstake
        // guardians thresholds
        uint8   deployerThreshold;    // e.g. 5-of-7
        uint8   adminThreshold;       // e.g. 5-of-7
        // durations
        uint256 termDurationBlocks;   // term stake duration
        // last honest guardian special window
        uint256 lastHonestWindow;     // e.g., 48h in blocks
    }

    event ConfigUpdated(bytes32 indexed key, uint256 value);
    modifier onlyAdmin(Storage storage s, address caller){ if (caller!=s.admin) revert NotAdmin(); _; }

    function init(Storage storage s, address admin_) internal {
        s.admin = admin_;
        s.baseRewardRate     = 1e18;
        s.blocksPerUnit      = 600;              // ~ 2 min blocks example
        s.perCollectionCap   = 20_000;
        s.globalCap          = 1_000_000_000;
        s.termCap            = 750_000_000;
        s.permCap            = 250_000_000;
        s.harvestFee         = 1e18;
        s.unstakeFee         = 1e18;
        s.deployerThreshold  = 5;
        s.adminThreshold     = 5;
        s.termDurationBlocks = 90_000;           // example
        s.lastHonestWindow   = 500_000;          // example
    }

    function setUint(Storage storage s, address caller, bytes32 key, uint256 v) internal onlyAdmin(s, caller){
        if (key == keccak256("baseRewardRate")) s.baseRewardRate = v;
        else if (key == keccak256("blocksPerUnit")) s.blocksPerUnit = v;
        else if (key == keccak256("perCollectionCap")) s.perCollectionCap = v;
        else if (key == keccak256("globalCap")) s.globalCap = v;
        else if (key == keccak256("termCap")) s.termCap = v;
        else if (key == keccak256("permCap")) s.permCap = v;
        else if (key == keccak256("harvestFee")) s.harvestFee = v;
        else if (key == keccak256("unstakeFee")) s.unstakeFee = v;
        else if (key == keccak256("termDurationBlocks")) s.termDurationBlocks = v;
        else if (key == keccak256("lastHonestWindow")) s.lastHonestWindow = v;
        else revert InvalidParam();
        emit ConfigUpdated(key,v);
    }

    function setThreshold(Storage storage s, address caller, bool deployerCouncil, uint8 t) internal onlyAdmin(s, caller){
        if (t==0 || t>7) revert InvalidParam();
        if (deployerCouncil) s.deployerThreshold = t; else s.adminThreshold = t;
    }
}
