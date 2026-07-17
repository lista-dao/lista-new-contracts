// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev OTC manager interface. The adapter pushes asset out to the OTC wallet
 * (Surfin's receiving multisig) through `swapToken`.
 */
interface IOTCManager {
  function swapToken(address token, uint256 amount) external;
}
