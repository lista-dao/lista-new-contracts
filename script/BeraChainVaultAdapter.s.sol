// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "../src/BeraChainVaultAdapter.sol";

contract BeraChainVaultAdapterScript is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/BeraChainVaultAdapter.s.sol:BeraChainVaultAdapterScript --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/BeraChainVaultAdapter.s.sol:BeraChainVaultAdapterScript --broadcast --verify -vvv --rpc-url <testnet-rpc> --etherscan-api-key <bscscan-api-key>
   * proxy: 0x493171878Ca4C37984Fe54Aa0491E5E0098D78FC
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

    address BTCB = vm.envAddress("BTCB_TOKEN");
    console.log("Token: %s", BTCB);
    address lpToken = vm.envAddress("BTCB_LP_TOKEN");
    console.log("LPToken: %s", lpToken);
    address operator = vm.envAddress("BTCB_VAULT_OPERATOR");
    console.log("Operator: %s", operator);
    uint256 depositEndTime = vm.envOr("BTCB_VAULT_END_TIME", uint256(1738367999));
    console.log("DepositEndTime: %s", depositEndTime);
    uint256 depositMinAmount = vm.envOr("BTCB_VAULT_MIN_DEPOSIT_AMOUNT", uint256(1000000000000000));
    console.log("DepositMinAmount: %s", depositMinAmount);

    vm.startBroadcast(deployerPrivateKey);
    address proxy = Upgrades.deployUUPSProxy(
      "BeraChainVaultAdapter.sol",
      abi.encodeCall(
        BeraChainVaultAdapter.initialize,
        (admin, manager, pauser, bot, BTCB, lpToken, operator, depositEndTime, depositMinAmount)
      )
    );
    vm.stopBroadcast();
    console.log("BeraChainVaultAdapter proxy address: %s", proxy);
    address implAddress = Upgrades.getImplementationAddress(proxy);
    console.log("BeraChainVaultAdapter impl address: %s", implAddress);
  }
}
