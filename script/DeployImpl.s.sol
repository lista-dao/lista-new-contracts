// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { Options } from "openzeppelin-foundry-upgrades/Options.sol";

contract DeployImplScript is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/DeployImpl.s.sol:DeployImplScript --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/DeployImpl.s.sol:DeployImplScript --broadcast --verify -vvv --rpc-url https://bsc-testnet-dataseed.bnbchain.org --etherscan-api-key <bscscan-api-key>
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    string memory contractName = vm.envString("IMPL_CONTRACT");
    console.log("Contract: %s", contractName);

    vm.startBroadcast(deployerPrivateKey);
    Options memory opts;
    address implAddress = Upgrades.deployImplementation(contractName, opts);
    console.log("New impl: %s", implAddress);
    vm.stopBroadcast();
  }
}
