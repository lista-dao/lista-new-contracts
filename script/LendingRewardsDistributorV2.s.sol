// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "../src/LendingRewardsDistributorV2.sol";

contract LendingRewardsDistributorV2Script is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/LendingRewardsDistributorV2.s.sol:LendingRewardsDistributorScript --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/LendingRewardsDistributorV2.s.sol:LendingRewardsDistributorV2Script --broadcast --verify -vvv --rpc-url bsc_testnet --etherscan-api-key <bscscan-api-key>
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

    address lista = 0x90b94D605E069569Adf33C0e73E26a83637c94B1; // testnet
    address lisUSD = 0x785b5d1Bde70bD6042877cA08E4c73e0a40071af; // testnet

    address[] memory tokens = new address[](2);
    tokens[0] = lista;
    tokens[1] = lisUSD;

    vm.startBroadcast(deployerPrivateKey);
    address proxy = Upgrades.deployUUPSProxy(
      "LendingRewardsDistributorV2.sol",
      abi.encodeCall(LendingRewardsDistributorV2.initialize, (deployer, deployer, deployer, deployer, tokens))
    );
    vm.stopBroadcast();
    console.log("LendingRewardsDistributorV2 proxy address: %s", proxy);
    address implAddress = Upgrades.getImplementationAddress(proxy);
    console.log("LendingRewardsDistributorV2 impl address: %s", implAddress);
  }
}
