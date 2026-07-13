// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Script.sol";

import { AtlasOracleAdaptor } from "@src/oracle/AtlasOracleAdaptor.sol";

/**
 * @title DeployAtlasOracleAdaptors
 * @notice Deploys one AtlasOracleAdaptor per unique Atlas Oracle push feed
 * Run with:
 *   forge script script/oracle/deployAtlasOracleAdaptors.sol:DeployAtlasOracleAdaptors \
 *     --rpc-url $BSC_RPC --broadcast --slow -vvvv
 */
contract DeployAtlasOracleAdaptors is Script {
  struct Feed {
    string symbol;
    address pushContract;
  }

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);

    Feed[1] memory feeds = [
      // ----- Atlas tokenized-equity / RWA push feeds (already deployed) -----
      // Feed("TSLAB/USD", 0xC64bF44C23586aE5eab37775662Dc1E0c56469fe),
      // Feed("NVDAB/USD", 0x67d168bF5d7851a7b361bFFcf794696858F9697A),
      // Feed("SNDKB/USD", 0xEb856d62Bdf5b00C5a62c44B3fF94caF5F5d32DC),
      // Feed("CRCLB/USD", 0x3Fe4Ad1BBb3ad138AA7d8a63a9A2984eC9641064),
      // Feed("MUB/USD", 0xcC8d5Ffd711A85775EECB4EcE319eDDCC5EeBCE5),
      // Feed("SPCXB/USD", 0xCf5D24C987caCD4155C83aBB95fA86951D3832f9)
      // Feed("MSTRB/USD", 0x5453B1ABf6029A5d05De56D48d3a835Df80b7A7f),
      // Feed("INTCB/USD", 0x04676ef12A9787761DDd0d1e27522c4a65b64262),
      // Feed("EWYB/USD", 0xEb8AeD013806f9682a8B4530Ae3E9CE47F3f76B5),
      // Feed("AMDB/USD", 0xBF0D0cDb25bc20C809190836b14AE902AEc17EaC)
      // ----- Batch 3 tokenized-equity push feeds (already deployed) -----
      // Feed("MSFTB/USD", 0xe39fC955A9b926d5ce0242505006611678180307),
      // Feed("METAB/USD", 0xD53300F42830552D826244fc17a6A0a4a95980A6),
      // Feed("PLTRB/USD", 0x485568bd19d587fF67F465EEff135C1F0745751C),
      // Feed("LITEB/USD", 0x617EC012e45B864d140d3F3B3912DDa210979ea5),
      // Feed("QQQB/USD", 0x7D2f703D2A188f32310dC9707E86acE503207027)
      // ----- Batch 4 tokenized-equity push feeds (already deployed) -----
      // Feed("CBRSB/USD", 0xB3FC5F9187EBE4640985E6607DDe7DE1C7067B04),
      // Feed("COINB/USD", 0x758aB25F2Db37AAE2CC09D5542B2C69b5fC70E61),
      // Feed("DRAMB/USD", 0x6eaed198cA7d86C7982C30CAC4dc1c28BE915744),
      // Feed("GLWB/USD", 0x60014fD4FcdB9778C771f510BC6F1abBa824c8f6),
      // Feed("GOOGLB/USD", 0x2FcEafD81a4dBDa2409B6fe5ce2afFe3cD46eDbC),
      // Feed("NBISB/USD", 0x50f67D3CE440A98fFeC832726260ae03667fbE5E),
      // Feed("QCOMB/USD", 0x22772c763Fc2B44eD59Da2BD309Fa8E4D00261f5),
      // Feed("SOXLB/USD", 0xbFC8C863B14f08e07e789328A424137E2B5933F4),
      // Feed("SPYB/USD", 0xCda6d5cE036AC0D6A387A377062EBd18Dd531177),
      // Feed("WDCB/USD", 0x583e282D4C914E1Faf47235769431899D7A5fB99)
      // ----- Batch 5 tokenized-equity push feeds -----
      Feed("SKHYB/USD", 0xAF61b3f158284F4208E75b14B1A0e362e2c79738)
    ];

    vm.startBroadcast(deployerPrivateKey);

    for (uint256 i = 0; i < feeds.length; i++) {
      AtlasOracleAdaptor adaptor = new AtlasOracleAdaptor(feeds[i].pushContract);
      console.log("AtlasOracleAdaptor", feeds[i].symbol, "->", address(adaptor));
      console.log("  underlying Atlas feed:", feeds[i].pushContract);
    }

    vm.stopBroadcast();
  }
}
