// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAstherusVault } from "../../../src/lisaster/interface/IAstherusVault.sol";

/// @notice Test-only. Mimics the AstherusVault BSC `depositFor`: pulls ASTER into this
///         contract and records call parameters. On real BSC the Astherus backend syncs the
///         credited balance to Aster Chain within 1-3 minutes.
contract MockAstherusVault is IAstherusVault {
  using SafeERC20 for IERC20;

  struct DepositCall {
    address currency;
    address forAddress;
    uint256 amount;
    uint256 broker;
  }

  DepositCall[] public calls;

  function depositFor(address currency, address forAddress, uint256 amount, uint256 broker) external payable override {
    IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
    calls.push(DepositCall(currency, forAddress, amount, broker));
  }

  function callsLength() external view returns (uint256) {
    return calls.length;
  }
}
