// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAsterVault {
  event Deposited(address indexed user, address indexed receiver, uint256 amount);

  /// @notice Deposit ASTER. Internally calls `AstherusVault.depositFor` with
  ///         `forAddress = lisAsterManager`; Astherus's backend syncs the credited balance to
  ///         Aster Chain within 1-3 minutes. Mints lisAster 1:1 to `receiver` in the same tx.
  /// @dev Callable by anyone. Two production callers: user deposits, and `LisAsterRewards`
  ///      re-depositing reward ASTER returned via Astherus.withdraw (not a reentry attack
  ///      surface -- the vault is `nonReentrant` and this is a legitimate outer-frame entry).
  function deposit(uint256 amount, address receiver) external;
}
