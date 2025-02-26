// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "../src/VeListaInterestRebater.sol";

contract VeListaInterestRebaterScript is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/VeListaInterestRebater.s.sol:VeListaInterestRebaterScript --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/VeListaInterestRebater.s.sol:VeListaInterestRebaterScript --broadcast --verify -vvv --rpc-url <testnet-rpc> --etherscan-api-key <bscscan-api-key>
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

    address lisUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;


    vm.startBroadcast(deployerPrivateKey);
    address proxy = Upgrades.deployUUPSProxy(
      "VeListaInterestRebater.sol",
      abi.encodeCall(
        VeListaInterestRebater.initialize,
        (admin, manager, bot, pauser, lisUSD)
      )
    );
    vm.stopBroadcast();
    console.log("VeListaInterestRebater proxy address: %s", proxy);
    address implAddress = Upgrades.getImplementationAddress(proxy);
    console.log("VeListaInterestRebater impl address: %s", implAddress);
  }
}
