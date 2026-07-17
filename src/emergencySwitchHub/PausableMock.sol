// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title PausableMock
 * @author Lista
 * @dev Mock pausable contract used to exercise the EmergencySwitchHub on testnet.
 *      It mirrors the access pattern of the real core contracts (Moolah,
 *      StableSwapPool, XAUTStaking, ...): only the EmergencySwitchHub is allowed
 *      to pause / unpause. The on-chain `name` lets each mock stand in for a
 *      specific core contract when filling the deployment tables.
 */
contract PausableMock is Pausable {
  /// @dev human readable name of the core contract this mock represents
  string public name;
  /// @dev the EmergencySwitchHub allowed to pause / unpause this contract
  address public emergencySwitchHub;

  modifier onlyEmergencySwitchHub() {
    require(msg.sender == emergencySwitchHub, "PausableMock/not-EmergencySwitchHub");
    _;
  }

  constructor(string memory _name, address _emergencySwitchHub) {
    name = _name;
    emergencySwitchHub = _emergencySwitchHub;
  }

  function pause() external onlyEmergencySwitchHub {
    _pause();
  }

  function unpause() external onlyEmergencySwitchHub {
    _unpause();
  }
}
