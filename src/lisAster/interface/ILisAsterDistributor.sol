// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILisAsterDistributor {
  event Notified(uint256 amount);
  event MerkleRootSet(bytes32 root, uint256 totalAllocated);
  event Claimed(address indexed account, uint256 amount, uint256 cumulativeAmount);
  event ClaimedAndStaked(address indexed account, uint256 amount, uint256 cumulativeAmount);

  /// @notice Called by Rewards. Pulls `amount` lisAster from Rewards via transferFrom and
  ///         bumps `totalNotified`. Requires Rewards to approve beforehand.
  function notifyRewards(uint256 amount) external;

  /// @notice Overwrite the Merkle root. Leaf format:
  ///         `keccak256(abi.encode(chainid, account, cumulativeAmount))`.
  /// @param totalAllocated Sum of all leaves' `cumulativeAmount`. Must be monotonically
  ///        non-decreasing and <= `totalNotified`.
  function setMerkleRoot(bytes32 root, uint256 totalAllocated) external;

  function claim(address account, uint256 cumulativeAmount, bytes32[] calldata proof) external;

  function claimAndStake(address account, uint256 cumulativeAmount, bytes32[] calldata proof) external;

  function claimable(
    address account,
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) external view returns (uint256);
}
