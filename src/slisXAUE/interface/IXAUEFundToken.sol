// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Subset of XAUE Protocol FundToken (CoboFundToken) used by XAUEAdapter.
///         Mainnet impl: 0x495cba69b767aad0712bae0579372132bc03676a (proxy 0xd5D6...87a)
interface IXAUEFundToken is IERC20 {
  /// @notice Sync mint: pulls assetAmount XAUT from msg.sender, mints sharesAmount XAUE in return.
  ///         XAUT is transferred from msg.sender to the FundToken's vault directly.
  ///         Caller must be whitelisted.
  function mint(uint256 assetAmount) external returns (uint256 shareAmount);

  /// @notice Step 1 of async redeem: burns msg.sender's XAUE shares immediately and records a
  ///         RedemptionRequest. assetAmount is locked at NAV at this moment.
  function requestRedemption(uint256 shareAmount) external returns (uint256 reqId);

  function whitelist(address account) external view returns (bool);
  function minDepositAmount() external view returns (uint256);
  function minRedeemShares() external view returns (uint256);
  function paused() external view returns (bool);
}
