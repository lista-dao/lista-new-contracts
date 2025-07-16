// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SafeGuard } from "../../src/safe/SafeGuard.sol";

contract SafeGuardScript is Script {
  function setUp() public {}

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    vm.startBroadcast(deployerPrivateKey);
    SafeGuard safe = new SafeGuard();
    vm.stopBroadcast();
    console.log("SafeGuard address: %s", address(safe));
  }
}
