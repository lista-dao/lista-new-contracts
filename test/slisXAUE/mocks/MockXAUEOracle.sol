// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Test-only oracle. NAV is freely settable; no APR/maxAprDelta enforcement.
contract MockXAUEOracle {
  uint256 public price; // 1e18 scale: XAUT per XAUE share × 1e18

  constructor(uint256 _initialPrice) {
    price = _initialPrice;
  }

  function setPrice(uint256 _price) external {
    price = _price;
  }

  function getLatestPrice() external view returns (uint256) {
    return price;
  }
}
