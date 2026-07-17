// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Interface the SurfinAdapter uses to fund the InterestDistributor.
 *
 * Interest is distributed to users through a cumulative Merkle tree held by the
 * InterestDistributor. Funds live on the adapter, so the adapter tops the
 * distributor up via `notifyReward` (guarded by the FUNDER role) before a new
 * root is published; users then claim their cumulative interest directly from
 * the distributor.
 */
interface IInterestDistributor {
  /// @dev returns whether the token is a whitelisted interest token
  function tokens(address token) external view returns (bool);

  /// @dev fund the distributor with interest to distribute; pulls `amount` of
  ///      `token` from the caller, who must hold the FUNDER role
  function notifyReward(address token, uint256 amount) external;
}
