// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Subset of XAUE Protocol Oracle (CoboFundOracle).
///         getLatestPrice returns NAV scaled to 1e18 (XAUT per XAUE share × 1e18).
interface IXAUEOracle {
  function getLatestPrice() external view returns (uint256);
}
