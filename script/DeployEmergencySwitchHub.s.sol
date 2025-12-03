// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { EmergencySwitchHub } from "../src/emergencySwitchHub/EmergencySwitchHub.sol";

contract DeployEmergencySwitchHubScript is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/DeployEmergencySwitchHub.s.sol --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);
    address admin = vm.envOr("ADMIN", deployer);
    console.log("Admin: %s", admin);
    address manager = vm.envOr("MANAGER", deployer);
    console.log("Manager: %s", manager);
    address pauser = vm.envOr("PAUSER", deployer);
    console.log("Pauser: %s", pauser);

    vm.startBroadcast(deployerPrivateKey);
    address proxy = Upgrades.deployUUPSProxy(
      "EmergencySwitchHub.sol",
      abi.encodeCall(EmergencySwitchHub.initialize, (admin, manager, pauser))
    );
    vm.stopBroadcast();
    console.log("EmergencySwitchHub proxy address: %s", proxy);
    address implAddress = Upgrades.getImplementationAddress(proxy);
    console.log("EmergencySwitchHub impl address: %s", implAddress);
  }
}
