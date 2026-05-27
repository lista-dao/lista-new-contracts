// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAsterVault {
  event Deposited(address indexed user, address indexed receiver, uint256 amount);

  /// @notice Deposit ASTER. Internally calls `AstherusVault.depositFor` with
  ///         `forAddress = lisAsterManager`; Astherus's backend syncs the credited balance to
  ///         Aster Chain within 1-3 minutes. Mints lisAster 1:1 to `receiver` in the same tx.
  /// @dev Callable by anyone. Two production callers: user deposits, and
  ///      `LisAsterDistributor.claimAndStake` routing claimed ASTER into a staked position
  ///      (legitimate outer-frame entry; the vault is `nonReentrant`).
  function deposit(uint256 amount, address receiver) external;
}
