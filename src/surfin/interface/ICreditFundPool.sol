// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface the SurfinAdapter uses to drive an EarnPool (flex or locked).
 *
 * Funds always live in the adapter; the pool only keeps accounting. The adapter
 * therefore is the only caller of `finishWithdraw` (repays the batch queue) and
 * `addClaimableInterest` (books interest that users can later claim).
 */
interface ICreditFundPool {
  /// @dev asset token of the pool (USDT)
  function asset() external view returns (address);

  /// @dev total user principal booked in the pool (1:1 with LP for flex, sum of positions for locked)
  function totalPrincipal() external view returns (uint256);

  /// @dev principal that has been requested for withdraw but not yet claimed
  function totalPendingWithdraw() external view returns (uint256);

  /// @dev repay the batch withdraw queue; adapter transfers `amount` in first
  function finishWithdraw(uint256 amount) external;

  /// @dev book claimable interest for a set of users; adapter transfers the total in first
  function addClaimableInterest(address[] calldata users, uint256[] calldata amounts) external;
}
