// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILisAsterStaking {
  event Staked(address indexed from, address indexed receiver, uint256 amount);
  event Unstaked(address indexed user, uint256 amount);
  event DistributorSet(address indexed distributor);

  function stake(uint256 amount) external;

  /// @notice Permissionless stake-for: caller supplies lisAster, `receiver` gets the position.
  ///         Primary consumer is `LisAsterDistributor.claimAndStake`, but no on-chain check
  ///         enforces this -- any address may call.
  function stakeFor(address receiver, uint256 amount) external;

  function unstake(uint256 amount) external;

  function balanceOf(address user) external view returns (uint256);

  function totalSupply() external view returns (uint256);
}
