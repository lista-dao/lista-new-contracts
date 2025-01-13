// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "../../src/token/NonTransferableLpERC20.sol";

contract BTCBLPScript is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/token/BTCBLP.s.sol:BTCBLPScript --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/token/BTCBLP.s.sol:BTCBLPScript --broadcast --verify -vvv --rpc-url <testnet-rpc> --etherscan-api-key <bscscan-api-key>
   * proxy: 0x2d8645D3b8D2bAfd14ed4DCa4AD8D7D285D2fFe4
   * impl: 0x700913b4bc4d6443f8c5536d40814d66a3fd3635
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    vm.startBroadcast(deployerPrivateKey);
    address proxy = Upgrades.deployUUPSProxy(
      "NonTransferableLpERC20.sol",
      abi.encodeCall(NonTransferableLpERC20.initialize, ("Lista Bera BTC", "lisBBTC"))
    );
    vm.stopBroadcast();
    console.log("ListaBeraBTC proxy address: %s", proxy);
    address implAddress = Upgrades.getImplementationAddress(proxy);
    console.log("ListaBeraBTC impl address: %s", implAddress);
  }
}
