// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import { AtlasMultiFeedAdaptor } from "@src/oracle/AtlasMultiFeedAdaptor.sol";
import { IAtlasMultiFeed } from "@src/oracle/interfaces/IAtlasMultiFeed.sol";

/**
 * @notice Deploys the hardcoded Atlas MultiFeed adaptors on BSC; does not configure ResilientOracle.
 * @dev Required env: DEPLOYER_PRIVATE_KEY. The feed IDs and their published
 * heartbeats are hardcoded below so every deployment batch is reviewed in the
 * diff instead of supplied at the shell. Each feed's deployment preflight
 * rejects a price older than its heartbeat plus MAX_AGE_BUFFER.
 *
 * Dry run (add --broadcast --slow only for an approved deployment):
 * forge script script/oracle/deployAtlasMultiFeedAdaptors.sol:DeployAtlasMultiFeedAdaptors --rpc-url bsc
 */
contract DeployAtlasMultiFeedAdaptors is Script {
  struct Feed {
    string symbol;
    uint32 feedId;
    uint32 heartbeat; // Publisher-declared update interval, in seconds.
  }

  address public constant ATLAS_MULTI_FEED = 0xEAcE519ebB14fB8404fA6DdD23C3b34abaDE44aa;

  /// @notice Seconds allowed on top of a feed's heartbeat before the deployment preflight rejects its price.
  uint256 public constant MAX_AGE_BUFFER = 300;

  function run() public returns (AtlasMultiFeedAdaptor[] memory adaptors) {
    // ----- Batch 0 (already deployed) -----
    // Feed("QQQB/USD", 947, 60)
    // ----- Batch 1 -----
    Feed[] memory feeds = new Feed[](2);
    feeds[0] = Feed("GPROB/USD", 1053, 60);
    feeds[1] = Feed("RDDTB/USD", 1054, 60);

    return _deploy(feeds, vm.envUint("DEPLOYER_PRIVATE_KEY"));
  }

  function _deploy(
    Feed[] memory feeds,
    uint256 deployerPrivateKey
  ) internal returns (AtlasMultiFeedAdaptor[] memory adaptors) {
    require(block.chainid == 56, "AtlasMultiFeedDeploy/not-bsc");
    require(feeds.length != 0, "AtlasMultiFeedDeploy/empty-feeds");
    // This script targets the public BNB Chain registry. Whitelist-only sources
    // need a separate deployment/access plan for the actual adaptor addresses.
    require(IAtlasMultiFeed(ATLAS_MULTI_FEED).isOpenRead(), "AtlasMultiFeedDeploy/not-open-read");

    for (uint256 i; i < feeds.length; ++i) {
      require(feeds[i].heartbeat != 0, "AtlasMultiFeedDeploy/zero-heartbeat");
      require(bytes(feeds[i].symbol).length != 0, "AtlasMultiFeedDeploy/empty-symbol");
      for (uint256 j; j < i; ++j) {
        require(feeds[i].feedId != feeds[j].feedId, "AtlasMultiFeedDeploy/duplicate-feed");
      }
    }

    adaptors = new AtlasMultiFeedAdaptor[](feeds.length);
    vm.startBroadcast(deployerPrivateKey);
    for (uint256 i; i < feeds.length; ++i) {
      adaptors[i] = new AtlasMultiFeedAdaptor(ATLAS_MULTI_FEED, bytes4(feeds[i].feedId), feeds[i].symbol);
    }
    vm.stopBroadcast();

    // Validate deployed contract calls, not EOA/constructor-only access. Foundry
    // runs these checks in the dry run before broadcasting the deployment batch.
    for (uint256 i; i < feeds.length; ++i) {
      uint256 maxPriceAge = uint256(feeds[i].heartbeat) + MAX_AGE_BUFFER;
      (, int256 answer, , uint256 updatedAt, ) = adaptors[i].latestRoundData();
      require(block.timestamp - updatedAt <= maxPriceAge, "AtlasMultiFeedDeploy/stale-price");
      console.log("Symbol:", feeds[i].symbol);
      console.log("Feed ID:", feeds[i].feedId);
      console.log("Description:", adaptors[i].description());
      console.log("Adaptor:", address(adaptors[i]));
      console.log("USD price (8 decimals):", uint256(answer));
      console.log("Aggregated at:", updatedAt);
      console.log("Max price age (s):", maxPriceAge);
    }
  }
}
