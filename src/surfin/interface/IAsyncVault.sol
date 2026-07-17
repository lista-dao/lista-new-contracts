// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Minimal async (ERC-7540 style) vault interface.
 *
 * This is RESERVED for future yield sources such as a PSM / Venus style vault
 * where idle buffer funds can earn yield while staying instantly redeemable.
 * The SurfinAdapter keeps the same deposit/redeem plumbing that RWAAdapter uses
 * so a liquid yield source can be plugged in later without touching the pools.
 */
interface IAsyncVault {
  function totalAssets() external view returns (uint256);

  function convertToShares(uint256 assets) external view returns (uint256);

  function convertToAssets(uint256 shares) external view returns (uint256);

  function balanceOf(address account) external view returns (uint256);

  function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256);

  function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256);

  function maxMint(address account) external view returns (uint256);

  function maxRedeem(address account) external view returns (uint256);

  function mint(uint256 shares, address receiver) external returns (uint256);

  function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}
