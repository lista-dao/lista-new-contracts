// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILisAsterRewards {
  event RewardsNotified(uint256 asterAmount, uint256 fee, uint256 lisAsterMinted);
  event RewardsDistributed(uint256 amount);
  event DistributorSet(address indexed distributor);
  event SetFeeReceiver(address indexed feeReceiver);
  event SetFeeRate(uint256 feeRate);

  /// @notice MANAGER transfers ASTER in; a fraction (`feeRate`) is forwarded to `feeReceiver`
  ///         in ASTER form, and the rest re-enters Vault.deposit to mint lisAster to this
  ///         contract.
  function notifyRewards(uint256 amount) external;

  /// @notice BOT forwards accumulated lisAster to the Distributor and notifies it to update
  ///         `totalNotified`.
  function distributeRewards(uint256 amount) external;

  /// @notice Set the ASTER fee recipient. Required before `notifyRewards` if `feeRate > 0`.
  function setFeeReceiver(address r) external;

  /// @notice Set the fee rate (18 decimals, capped at `MAX_FEE_RATE`).
  function setFeeRate(uint256 r) external;

  function pendingLisAster() external view returns (uint256);
}
