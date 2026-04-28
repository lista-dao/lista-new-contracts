// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal subset of the AstherusVault BSC contract
///         (`0x128463A60784c4D3f46c23Af3f65Ed859Ba87974`). Operated by Astherus, it accepts
///         ASTER deposits on BSC and asynchronously syncs the credited balance to the same EOA
///         on Aster Chain (typically within 1-3 minutes). ASTER itself never leaves BSC; the
///         cross-chain visibility is provided by Astherus's off-chain ledger.
interface IAstherusVault {
  /// @notice Depositer supplies the asset and credits another address. Emits
  ///         `Deposit(forAddress, currency, false, amount, broker)`.
  /// @param currency   Deposited asset (always ASTER for lisAster).
  /// @param forAddress Astherus / Aster Chain account to credit. For Lista this is the
  ///                   `lisAsterManager` EOA.
  /// @param amount     Deposit amount.
  /// @param broker     Broker flag (uint256). Lista uses 1 by default.
  function depositFor(address currency, address forAddress, uint256 amount, uint256 broker) external payable;
}
