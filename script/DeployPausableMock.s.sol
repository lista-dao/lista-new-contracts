// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { PausableMock } from "../src/emergencySwitchHub/PausableMock.sol";

contract DeployPausableMockScript is Script {
  /**
   * @dev Run the script
   * sepolia:
   * NAME=Moolah EMERGENCY_SWITCH_HUB=0x... \
   *   forge script script/DeployPausableMock.s.sol --rpc-url <sepolia-rpc> --etherscan-api-key <etherscan-api-key> --broadcast --verify -vvv
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    string memory name = vm.envOr("NAME", string("PausableMock"));
    console.log("Name: %s", name);
    address emergencySwitchHub = vm.envAddress("EMERGENCY_SWITCH_HUB");
    console.log("EmergencySwitchHub: %s", emergencySwitchHub);

    vm.startBroadcast(deployerPrivateKey);
    PausableMock mock = new PausableMock(name, emergencySwitchHub);
    vm.stopBroadcast();

    console.log("PausableMock address: %s", address(mock));
  }
}
