// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev the slice of the SurfinAdapter a pool needs. The pool never drives the adapter;
///      it only checks they were wired around the same asset.
interface ISurfinAdapter {
  function asset() external view returns (address);
}
