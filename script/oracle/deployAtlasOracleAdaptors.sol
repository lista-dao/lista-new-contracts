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

    Feed[4] memory feeds = [
      // ----- Atlas tokenized-equity / RWA push feeds (already deployed) -----
      // Feed("TSLAB/USD", 0xC64bF44C23586aE5eab37775662Dc1E0c56469fe),
      // Feed("NVDAB/USD", 0x67d168bF5d7851a7b361bFFcf794696858F9697A),
      // Feed("SNDKB/USD", 0xEb856d62Bdf5b00C5a62c44B3fF94caF5F5d32DC),
      // Feed("CRCLB/USD", 0x3Fe4Ad1BBb3ad138AA7d8a63a9A2984eC9641064),
      // Feed("MUB/USD", 0xcC8d5Ffd711A85775EECB4EcE319eDDCC5EeBCE5),
      // Feed("SPCXB/USD", 0xCf5D24C987caCD4155C83aBB95fA86951D3832f9)
      // ----- New tokenized-equity push feeds -----
      Feed("MSTRB/USD", 0x5453B1ABf6029A5d05De56D48d3a835Df80b7A7f),
      Feed("INTCB/USD", 0x04676ef12A9787761DDd0d1e27522c4a65b64262),
      Feed("EWYB/USD", 0xEb8AeD013806f9682a8B4530Ae3E9CE47F3f76B5),
      Feed("AMDB/USD", 0xBF0D0cDb25bc20C809190836b14AE902AEc17EaC)
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
