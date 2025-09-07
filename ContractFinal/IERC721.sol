// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address a) external view returns (uint256);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}
