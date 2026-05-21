// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISlisXAUE is IERC20 {
  /// @notice Mint shares. Only callable by MINTER (XAUTStaking).
  function mint(address to, uint256 amount) external;

  /// @notice Burn shares from an arbitrary account. Only callable by MINTER.
  /// @dev MINTER is trusted (the XAUTStaking business-logic contract); used at requestWithdraw to burn user shares.
  function burn(address from, uint256 amount) external;
}
