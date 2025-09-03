// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRWAEarnPool {
  function withdrawFromVault() external;
  function finishWithdraw(uint256 amount) external;
  function requestDepositToVault(uint256 amount) external;
  function notifyInterest(uint256 amount) external;
}
