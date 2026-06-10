// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IXAUTStaking {
  /// @notice Adapter pushes net interest to update share rate. Convert rate jumps immediately (no vesting).
  function increaseTotalAssets(uint256 amount) external;

  /// @notice Adapter delivers XAUT back to staking to cover pending withdrawal batches (FIFO).
  function finishWithdraw(uint256 amount) external;

  function totalAssets() external view returns (uint256);
  function convertToShares(uint256 assets) external view returns (uint256);
  function convertToAssets(uint256 shares) external view returns (uint256);
}
