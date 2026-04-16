// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { Options } from "openzeppelin-foundry-upgrades/Options.sol";

import "../../src/rwa/RWAAdapter.sol";

contract DeployRWAAdapterImplScript is Script {
  // BSC Mainnet USDT
  address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;

  /**
   * @dev Deploy a new RWAAdapter implementation for upgrade
   *
   * Usage:
   * DEPLOYER_PRIVATE_KEY=<key> BSCSCAN_API_KEY=<key> \
   *   forge script script/rwa/deploy_rwaAdapter_impl.s.sol:DeployRWAAdapterImplScript \
   *   --rpc-url https://bsc-dataseed.binance.org \
   *   --etherscan-api-key <bscscan-api-key> \
   *   --broadcast --verify -vvv
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    vm.startBroadcast(deployerPrivateKey);

    // Deploy new implementation with same constructor args as the original
    // Both asset and vaultAsset are USDT for the current RWAAdapter deployments
    RWAAdapter newImpl = new RWAAdapter(USDT, USDT);
    console.log("New RWAAdapter implementation: %s", address(newImpl));

    vm.stopBroadcast();
  }
}
