// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";

import "../../src/mock/MockERC20.sol";

contract MockERC20Script is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/token/MockERC20.s.sol:MockERC20Script --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/token/MockERC20.s.sol:MockERC20Script --broadcast --verify -vvv --rpc-url bsc_testnet --etherscan-api-key <bscscan-api-key>
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    vm.startBroadcast(deployerPrivateKey);

    MockERC20 mockToken = new MockERC20("SOLV", "solv");

    console.log("mockToken address: %s", address(mockToken));
  }
}
