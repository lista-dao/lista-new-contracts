// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import { SafeGuard } from "../../src/safe/SafeGuard.sol";

contract SafeGuardScript is Script {
  // MultiSendCallOnly deployments, the only delegatecall targets allowed (same addresses on BSC / ETH)
  address constant MULTISEND_CALL_ONLY_130 = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D; // 1.3.0 canonical
  address constant MULTISEND_CALL_ONLY_130_EIP155 = 0xA1dabEF33b3B82c7814B6D82A79e50F4AC44102B; // 1.3.0 eip155
  address constant MULTISEND_CALL_ONLY_141 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2; // 1.4.1

  function setUp() public {}

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    address[] memory delegateTargets = new address[](3);
    delegateTargets[0] = MULTISEND_CALL_ONLY_130;
    delegateTargets[1] = MULTISEND_CALL_ONLY_130_EIP155;
    delegateTargets[2] = MULTISEND_CALL_ONLY_141;

    vm.startBroadcast(deployerPrivateKey);
    SafeGuard safe = new SafeGuard(delegateTargets);
    vm.stopBroadcast();
    console.log("SafeGuard address: %s", address(safe));
  }
}
