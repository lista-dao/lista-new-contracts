// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Script.sol";

import { wNLPPriceFeed } from "@src/oracle/wNLPPriceFeed.sol";
import "@src/oracle/interfaces/OracleInterface.sol";

/**
 * @title DeployWNLPSPCXBPriceFeed
 * @notice Deploys the wNLP-S5B/USD price feed used by the nSPCXB / SPCXB
 * whitelist market. nSPCXB is the product name for the wNLP-S5B wrapper
 * (on-chain symbol wNLP-S5B, name Wrapped NLP: S5B).
 *
 * Verified on BSC mainnet:
 *   wNLP-S5B.underlying()       = SPCXB 0xbe9D...03E1
 *   wNLP-S5B.nlp()              = NLP-S5B 0x4EE1C93E...4939
 *   wNLP-S5B.getNlpByWnlp(1e18) ~ 1.0151 (wrapper accrues, rate > 1)
 *   resilientOracle.peek(SPCXB) ~ 115 USD (8 decimals)
 *
 * After deployment the feed still has to be registered as the MAIN oracle of
 * wNLP-S5B on the ResilientOracle (setTokenConfigs, Ops multi-sig) and a
 * BoundValidator entry added, before peek(wNLP-S5B) resolves. Until then
 * Moolah.createMarket reverts, because it peeks both market tokens.
 *
 * Run with:
 *   forge script script/oracle/deployWNLPSPCXBPriceFeed.sol:DeployWNLPSPCXBPriceFeed \
 *     --rpc-url bsc --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify -vvvv
 */
contract DeployWNLPSPCXBPriceFeed is Script {
  // Lista ResilientOracle (BSC mainnet)
  address constant RESILIENT_ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  // wNLP-S5B wrapper == nSPCXB, the market collateral
  address constant WNLP_S5B = 0xF27760F7b431aD8cAeE0f4E3062E6140b14E0eBC;
  // SPCXB, the wrapper's underlying and the market loan token
  address constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;

  string constant DESCRIPTION = "wNLP-S5B/USD Price Feed";

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);

    vm.startBroadcast(deployerPrivateKey);

    wNLPPriceFeed feed = new wNLPPriceFeed(RESILIENT_ORACLE, WNLP_S5B, SPCXB, DESCRIPTION);

    vm.stopBroadcast();

    console.log("wNLPPriceFeed (wNLP-S5B) deployed ->", address(feed));
    console.log("  SPCXB (1e8):", OracleInterface(RESILIENT_ORACLE).peek(SPCXB));
    console.log("  wNLP-S5B (1e8):", uint256(feed.latestAnswer()));
  }
}
