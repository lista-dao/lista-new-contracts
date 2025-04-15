// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LisBNB interface
interface ILisBNB is IERC20 {
  function mint(address _account, uint256 _amount) external;
  function burn(address _account, uint256 _amount) external;
  function setMinter(address minter) external;
}
