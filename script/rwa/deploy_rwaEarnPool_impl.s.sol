// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../../src/rwa/RWAEarnPool.sol";

contract DeployRWAEarnPoolImplScript is Script {
  /**
   * @dev Deploy a new RWAEarnPool implementation for upgrade
   *
   * Usage:
   * DEPLOYER_PRIVATE_KEY=<key> BSCSCAN_API_KEY=<key> \
   *   forge script script/rwa/deploy_rwaEarnPool_impl.s.sol:DeployRWAEarnPoolImplScript \
   *   --rpc-url https://bsc-dataseed.binance.org \
   *   --etherscan-api-key <bscscan-api-key> \
   *   --broadcast --verify -vvv
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    vm.startBroadcast(deployerPrivateKey);

    RWAEarnPool newImpl = new RWAEarnPool();
    console.log("New RWAEarnPool implementation: %s", address(newImpl));

    vm.stopBroadcast();
  }
}
