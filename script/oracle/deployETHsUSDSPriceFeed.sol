// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Script.sol";

import { sUSDSPriceFeed, ISUSDS } from "@src/oracle/priceFeed/sUSDSPriceFeed.sol";
import "@src/oracle/interfaces/OracleInterface.sol";

/**
 * @title DeployETHsUSDSPriceFeed
 * @notice Deploys the sUSDS/USD price feed on Ethereum mainnet. sUSDS and USDS are
 * hardcoded constants in the feed, so only the ResilientOracle address is passed in.
 *
 * Verified on Ethereum mainnet:
 *   sUSDS.asset()                = USDS 0xdC03...384F
 *   sUSDS.convertToAssets(1e18)  ~ 1.1074 USDS (vault accrues, rate > 1)
 *   resilientOracle.peek(USDS)   ~ 0.99999917 USD (8 decimals)
 *   resilientOracle.peek(sUSDS)  reverts today - sUSDS is not configured yet
 *
 * After deployment the feed still has to be registered as the MAIN oracle of sUSDS
 * on the ResilientOracle (setTokenConfigs, Ops multi-sig) and a BoundValidator entry
 * added, before peek(sUSDS) resolves. Until then Moolah.createMarket reverts, because
 * it peeks both market tokens.
 *
 * Run with:
 *   forge script script/oracle/deployETHsUSDSPriceFeed.sol:DeployETHsUSDSPriceFeed \
 *     --rpc-url eth --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify -vvvv
 */
contract DeployETHsUSDSPriceFeed is Script {
  // Lista ResilientOracle (Ethereum mainnet)
  address constant RESILIENT_ORACLE = 0xA64FE284EB8279B9b63946DD51813b0116099301;
  // Sky USDS, the underlying priced by the ResilientOracle
  address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
  // Sky sUSDS (Savings USDS), the market collateral
  address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);

    vm.startBroadcast(deployerPrivateKey);

    sUSDSPriceFeed feed = new sUSDSPriceFeed(RESILIENT_ORACLE);

    vm.stopBroadcast();

    console.log("sUSDSPriceFeed deployed ->", address(feed));
    console.log("  sUSDS/USDS rate (1e18):", ISUSDS(SUSDS).convertToAssets(1e18));
    console.log("  USDS (1e8):", OracleInterface(RESILIENT_ORACLE).peek(USDS));
    console.log("  sUSDS (1e8):", uint256(feed.latestAnswer()));
  }
}
