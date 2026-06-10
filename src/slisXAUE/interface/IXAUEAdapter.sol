// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IXAUEAdapter {
  function depositToVault(uint256 assetAmount) external;
  function requestWithdrawFromVault(uint256 assetAmount) external;
  function finishEarnPoolWithdraw(uint256 amount) external;
  function acknowledgeReject(uint256 reqId) external;
  function claimFee(uint256 feeAmount) external;
  function updateVaultAssets() external;
  function getVaultTotalAssets() external view returns (uint256);
}
