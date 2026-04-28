// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILisAsterRewards {
  event RewardsNotified(uint256 asterAmount, uint256 lisAsterMinted);
  event RewardsDistributed(uint256 amount);
  event DistributorSet(address indexed distributor);

  /// @notice MANAGER transfers ASTER in; the call re-enters Vault.deposit to mint lisAster
  ///         to this contract.
  function notifyRewards(uint256 amount) external;

  /// @notice BOT forwards accumulated lisAster to the Distributor and notifies it to update
  ///         `totalNotified`.
  function distributeRewards(uint256 amount) external;

  function pendingLisAster() external view returns (uint256);
}
