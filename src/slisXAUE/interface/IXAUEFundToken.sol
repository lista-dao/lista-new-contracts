// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Subset of XAUE Protocol FundToken (CoboFundToken) used by XAUEAdapter.
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

  /// @notice Auto-generated getter on `RedemptionRequest[] public redemptions` of CoboFundToken.
  ///         Enum RedemptionStatus { Pending=0, Rejected=1, Executed=2 }. Adapter reads this in
  ///         `acknowledgeReject` to recover shareAmount + verify status without duplicating XAUE state.
  function redemptions(
    uint256 reqId
  )
    external
    view
    returns (uint256 id, address user, uint256 assetAmount, uint256 shareAmount, uint256 requestedAt, uint8 status);
}
