// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAsterRewards {
  event RewardsNotified(uint256 asterAmount, uint256 fee, uint256 net);
  event RewardsDistributed(uint256 amount);
  event DistributorSet(address indexed distributor);
  event SetFeeReceiver(address indexed feeReceiver);
  event SetFeeRate(uint256 feeRate);
  event SetOperator(address oldOperator, address newOperator);
  event EmergencyWithdrawn(address indexed token, address indexed to, uint256 amount);

  /// @notice BOT ingests ASTER pulled from `operator`; `feeRate` of it is forwarded to
  ///         `feeReceiver` and the net stays in this contract as ASTER, awaiting `distributeRewards`.
  function notifyRewards(uint256 amount) external;

  /// @notice BOT forwards accumulated ASTER to the Distributor and notifies it to update
  ///         `totalNotified`.
  function distributeRewards(uint256 amount) external;

  /// @notice Set the ASTER fee recipient. Required before `notifyRewards` if `feeRate > 0`.
  function setFeeReceiver(address r) external;

  /// @notice Set the fee rate (18 decimals, capped at `MAX_FEE_RATE`).
  function setFeeRate(uint256 r) external;

  /// @notice Set the operator: the ASTER reward source (Lista-operated EOA on Astherus / Aster
  ///         Chain). Required (non-zero) before BOT can call `notifyRewards`. Same entity/address
  ///         as AsterVault.lisAsterManager.
  function setOperator(address newOperator) external;

  /// @notice MANAGER escape hatch: evacuate stuck/over-pulled ASTER or mis-sent tokens to the
  ///         caller. Does not adjust accounting.
  function emergencyWithdraw(address token, uint256 amount) external;

  /// @notice ASTER currently held by this contract, ready to be forwarded to the Distributor.
  function pendingAster() external view returns (uint256);
}
