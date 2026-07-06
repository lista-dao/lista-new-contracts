// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Script.sol";

import { LisAsterPriceFeed } from "@src/oracle/LisAsterPriceFeed.sol";
import "@src/oracle/interfaces/OracleInterface.sol";

/**
 * @title DeployLisAsterPriceFeed
 * @notice Deploys the non-upgradable LisAsterPriceFeed. Both the ResilientOracle
 * source and the ASTER token address are hardcoded in the contract, so there is
 * nothing to configure at deploy time.
 * Run with:
 *   forge script script/oracle/deployLisAsterPriceFeed.sol:DeployLisAsterPriceFeed \
 *     --rpc-url bsc --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify -vvvv
 */
contract DeployLisAsterPriceFeed is Script {
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);

    vm.startBroadcast(deployerPrivateKey);

    LisAsterPriceFeed feed = new LisAsterPriceFeed();

    vm.stopBroadcast();

    console.log("LisAsterPriceFeed deployed ->", address(feed));
    console.log("  ASTER (1e8):", OracleInterface(feed.RESILIENT_ORACLE()).peek(feed.ASTER()));
    console.log("  lisAster (1e8):", uint256(feed.latestAnswer()));
  }
}
