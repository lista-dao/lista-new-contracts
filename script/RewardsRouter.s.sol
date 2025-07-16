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
   * forge script script/RewardsRouter.s.sol:RewardsRouterScript --rpc-url bsc  --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/RewardsRouter.s.sol:RewardsRouterScript --broadcast --verify -vvv --rpc-url bsc_testnet
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_BSC_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
    console.log("Admin: %s", admin);
    address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
    console.log("Manager: %s", manager);
    address pauser = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
    console.log("Pauser: %s", pauser);
    address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
    console.log("Bot: %s", bot);

    address[] memory distributors = new address[](1);

    address v2Distributor = 0x2993E9eA76f5839A20673e1B3cf6666ab5B3aE76;
    console.log("Distributor V2: %s", v2Distributor);
    distributors[0] = v2Distributor;

    vm.startBroadcast(deployerPrivateKey);
    address proxy = Upgrades.deployUUPSProxy(
      "RewardsRouter.sol",
      abi.encodeCall(RewardsRouter.initialize, (admin, manager, bot, pauser, distributors))
    );
    vm.stopBroadcast();
    console.log("RewardsRouter proxy address: %s", proxy);
    address implAddress = Upgrades.getImplementationAddress(proxy);
    console.log("RewardsRouter impl address: %s", implAddress);
  }
}
