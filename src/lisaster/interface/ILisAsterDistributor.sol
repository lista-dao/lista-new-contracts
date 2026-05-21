// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILisAsterDistributor {
  event Notified(uint256 amount);
  event SetPendingMerkleRoot(bytes32 root, uint256 totalAllocated, uint256 lastSetTime);
  event AcceptMerkleRoot(bytes32 root, uint256 totalAllocated, uint256 acceptedTime);
  event RevokePendingMerkleRoot(bytes32 root);
  event WaitingPeriodUpdated(uint256 waitingPeriod);
  event Claimed(address indexed account, uint256 amount, uint256 cumulativeAmount);
  event ClaimedAndStaked(address indexed account, uint256 amount, uint256 cumulativeAmount);
  event EmergencyWithdrawn(address indexed token, address indexed to, uint256 amount);

  /// @notice Called by Rewards. Pulls `amount` ASTER from Rewards via transferFrom and bumps
  ///         `totalNotified`. Requires Rewards to approve beforehand.
  function notifyRewards(uint256 amount) external;

  /// @notice Stage a candidate Merkle root. Called by BOT. Leaf format:
  ///         `keccak256(abi.encode(chainid, account, asterToken, cumulativeAmount))`.
  ///         `asterToken` is the distributor's reward token. Validation runs here so the
  ///         staged candidate is provably promotable later.
  /// @param totalAllocated Sum of all leaves' `cumulativeAmount`. Must be monotonically
  ///        non-decreasing relative to the live `totalAllocated` and <= `totalNotified`.
  function setPendingMerkleRoot(bytes32 root, uint256 totalAllocated) external;

  /// @notice Promote the staged pending root to live. Called by BOT once
  ///         `block.timestamp >= lastSetTime + waitingPeriod`. MANAGER retains veto power
  ///         via `revokePendingMerkleRoot` during the wait.
  function acceptMerkleRoot() external;

  /// @notice Discard the staged pending root. Called by MANAGER (e.g. wrong root staged by BOT).
  function revokePendingMerkleRoot() external;

  /// @notice Tune the time-lock window between staging and acceptance. Admin-only.
  function changeWaitingPeriod(uint256 newWaitingPeriod) external;

  /// @notice Transfers `cumulativeAmount - claimed[account]` ASTER to `account`. Permissionless.
  function claim(address account, uint256 cumulativeAmount, bytes32[] calldata proof) external;

  /// @notice Self-only: claims for `msg.sender`, then routes the ASTER through Vault.deposit
  ///         and Staking.stakeFor so the user ends with a staked lisAster position.
  ///         Reverts if the claimable amount is below `AsterVault.minDeposit`; use `claim`
  ///         instead in that case.
  function claimAndStake(uint256 cumulativeAmount, bytes32[] calldata proof) external;

  function claimable(
    address account,
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) external view returns (uint256);
}
