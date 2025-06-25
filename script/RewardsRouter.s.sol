// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "../src/RewardsRouter.sol";

contract RewardsRouterScript is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/RewardsRouter.s.sol:RewardsRouterScript --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/RewardsRouter.s.sol:RewardsRouterScript --broadcast --verify -vvv --rpc-url bsc_testnet --etherscan-api-key <bscscan-api-key>
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
    address bot = vm.envOr("BOT", deployer);
    console.log("Bot: %s", bot);

    address[] memory distributors = new address[](2);

    address v1Distributor = 0x90b94D605E069569Adf33C0e73E26a83637c94B1;
    address v2Distributor = 0x90b94D605E069569Adf33C0e73E26a83637c94B1;
    console.log("Distributor 0: %s", v1Distributor);
    console.log("Distributor 1: %s", v2Distributor);
    distributors[0] = v1Distributor;
    distributors[1] = v2Distributor;

    vm.startBroadcast(deployerPrivateKey);
    address proxy = Upgrades.deployUUPSProxy(
      "RewardsRouter.sol",
      abi.encodeCall(RewardsRouter.initialize, (deployer, deployer, deployer, deployer, distributors))
    );
    vm.stopBroadcast();
    console.log("RewardsRouter proxy address: %s", proxy);
    address implAddress = Upgrades.getImplementationAddress(proxy);
    console.log("RewardsRouter impl address: %s", implAddress);
  }
}
