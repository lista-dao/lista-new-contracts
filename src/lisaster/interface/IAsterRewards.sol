// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAsterRewards {
  event RewardsNotified(uint256 asterAmount, uint256 fee, uint256 net);
  event RewardsDistributed(uint256 amount);
  event DistributorSet(address indexed distributor);
  event SetFeeReceiver(address indexed feeReceiver);
  event SetFeeRate(uint256 feeRate);
  event SetOperator(address oldOperator, address newOperator);
  event OperatorAdded(address indexed operator);
  event OperatorRemoved(address indexed operator);
  event EmergencyWithdrawn(address indexed token, address indexed to, uint256 amount);

  /// @notice BOT ingests ASTER pulled from `operator`; `feeRate` of it is forwarded to
  ///         `feeReceiver` and the net stays in this contract as ASTER, awaiting `distributeRewards`.
  function notifyRewards(uint256 amount) external;

  /// @notice BOT ingests `amounts[i]` ASTER from each whitelisted `operators[i]`; `feeRate` of the total
  ///         is forwarded to `feeReceiver` and the net stays here awaiting `distributeRewards`.
  function notifyRewards(address[] calldata operators, uint256[] calldata amounts) external;

  /// @notice BOT forwards accumulated ASTER to the Distributor and notifies it to update
  ///         `totalNotified`.
  function distributeRewards(uint256 amount) external;

  /// @notice Set the ASTER fee recipient. Required before `notifyRewards` if `feeRate > 0`.
  function setFeeReceiver(address r) external;

  /// @notice Set the fee rate (18 decimals, capped at `MAX_FEE_RATE`).
  function setFeeRate(uint256 r) external;

  /// @notice Set the legacy `operator` and whitelist it. Same entity/address as
  ///         AsterVault.lisAsterManager. Does not de-list the previous operator; rotating a
  ///         source also needs `removeOperator(old)`.
  function setOperator(address newOperator) external;

  /// @notice Whitelist / remove an ASTER reward source.
  function addOperator(address op) external;

  function removeOperator(address op) external;

  /// @notice Operator-whitelist views.
  function isOperator(address op) external view returns (bool);

  function getOperators() external view returns (address[] memory);

  function operatorCount() external view returns (uint256);

  /// @notice MANAGER escape hatch: evacuate stuck/over-pulled ASTER or mis-sent tokens to the
  ///         caller. Does not adjust accounting.
  function emergencyWithdraw(address token, uint256 amount) external;

  /// @notice ASTER currently held by this contract, ready to be forwarded to the Distributor.
  function pendingAster() external view returns (uint256);
}
