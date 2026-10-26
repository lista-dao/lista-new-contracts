// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev the slice of the SurfinAdapter a pool needs: the asset and slot checks at wiring, and,
///      for a pool that forwards deposits to the partner, the deploy call.
interface ISurfinAdapter {
  function asset() external view returns (address);

  /// @dev the pools the adapter serves; a single-product stack leaves the other slot empty
  function flexPool() external view returns (address);

  function lockedPool() external view returns (address);

  /// @dev send `amount` of idle asset to the partner wallet; MANAGER-gated on the adapter
  function deployToSurfin(uint256 amount) external;
}
