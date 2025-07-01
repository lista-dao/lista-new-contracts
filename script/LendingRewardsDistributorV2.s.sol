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
   * forge script script/LendingRewardsDistributorV2.s.sol:LendingRewardsDistributorV2Script --rpc-url bsc  --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/LendingRewardsDistributorV2.s.sol:LendingRewardsDistributorV2Script --broadcast --verify -vvv --rpc-url bsc_testnet
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

    address lista = 0xFceB31A79F71AC9CBDCF853519c1b12D379EdC46;
    address solv = 0xabE8E5CabE24Cb36df9540088fD7cE1175b9bc52;

    address[] memory tokens = new address[](2);
    tokens[0] = lista;
    tokens[1] = solv;

    vm.startBroadcast(deployerPrivateKey);
    address proxy = Upgrades.deployUUPSProxy(
      "LendingRewardsDistributorV2.sol",
      abi.encodeCall(LendingRewardsDistributorV2.initialize, (admin, manager, bot, pauser, tokens))
    );

    vm.stopBroadcast();
    console.log("LendingRewardsDistributorV2 proxy address: %s", proxy);
    address implAddress = Upgrades.getImplementationAddress(proxy);
    console.log("LendingRewardsDistributorV2 impl address: %s", implAddress);
  }
}
