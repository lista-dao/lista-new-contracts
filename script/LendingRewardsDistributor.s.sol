// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "../src/LendingRewardsDistributor.sol";

contract LendingRewardsDistributorScript is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/LendingRewardsDistributor.s.sol:LendingRewardsDistributorScript --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/LendingRewardsDistributor.s.sol:LendingRewardsDistributorScript --broadcast --verify -vvv --rpc-url <testnet-rpc> --etherscan-api-key <bscscan-api-key>
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

    vm.startBroadcast(deployerPrivateKey);
    address proxy = Upgrades.deployUUPSProxy(
      "LendingRewardsDistributor.sol",
      abi.encodeCall(LendingRewardsDistributor.initialize, (admin, manager, bot, pauser, lista))
    );
    vm.stopBroadcast();
    console.log("LendingRewardsDistributor proxy address: %s", proxy);
    address implAddress = Upgrades.getImplementationAddress(proxy);
    console.log("LendingRewardsDistributor impl address: %s", implAddress);
  }
}
