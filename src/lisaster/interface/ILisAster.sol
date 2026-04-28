// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice lisAster, the 1:1 LST of ASTER. The MINTER role is granted exclusively to AsterVault.
interface ILisAster is IERC20 {
  function mint(address to, uint256 amount) external;

  function burn(address from, uint256 amount) external;
}
