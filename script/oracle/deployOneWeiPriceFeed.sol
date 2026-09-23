// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Script.sol";

import { OneWeiPriceFeed } from "@src/oracle/priceFeed/OneWeiPriceFeed.sol";

/**
 * @title DeployOneWeiPriceFeed
 * @notice Deploys the non-upgradable OneWeiPriceFeed. The feed is stateless and
 * has no constructor arguments, no price source and no admin, so there is nothing
 * to configure at deploy time.
 *
 * The feed always answers 1 on an 8-decimal scale (1e-8 USD). To make it effective
 * it still has to be registered as the MAIN oracle of the target asset on the
 * ResilientOracle (setTokenConfigs, Ops multi-sig) with a matching BoundValidator
 * entry, before peek(asset) resolves.
 *
 * Run with:
 *   forge script script/oracle/deployOneWeiPriceFeed.sol:DeployOneWeiPriceFeed \
 *     --rpc-url bsc --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify -vvvv
 */
contract DeployOneWeiPriceFeed is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);

    vm.startBroadcast(deployerPrivateKey);

    OneWeiPriceFeed feed = new OneWeiPriceFeed();

    vm.stopBroadcast();

    console.log("OneWeiPriceFeed deployed ->", address(feed));
    console.log("  decimals:", feed.decimals());
    console.log("  answer (1e8):", uint256(feed.latestAnswer()));
  }
}
