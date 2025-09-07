// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 v) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
    function approve(address s, uint256 v) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
