// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILendingRewardsDistributorV2 {
  /// @dev returns whether the token is a whitelisted reward token
  function tokens(address token) external view returns (bool);
}
