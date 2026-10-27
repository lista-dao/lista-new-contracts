// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev the slice of the SurfinAdapter a pool needs: the asset and slot checks at wiring, and,
///      for a pool that forwards deposits to the partner, the deploy call.
interface ISurfinAdapter {
  function asset() external view returns (address);

  /// @dev the pools the adapter serves; a single-product stack leaves the other slot empty
  function flexPool() external view returns (address);

  function lockedPool() external view returns (address);

  /// @dev forward a deposit just paid in, capped at the adapter's maxDeployToSurfin() (the
  ///      rest stays on the adapter); callable only by the flex-slot pool
  function deployFromPool(uint256 amount) external;
}
