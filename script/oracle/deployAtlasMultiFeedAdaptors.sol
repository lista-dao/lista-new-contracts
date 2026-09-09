// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import { AtlasMultiFeedAdaptor } from "@src/oracle/AtlasMultiFeedAdaptor.sol";
import { IAtlasMultiFeed } from "@src/oracle/interfaces/IAtlasMultiFeed.sol";

/**
 * @notice Deploys selected Atlas MultiFeed adaptors on BSC; does not configure ResilientOracle.
 * @dev Required env: DEPLOYER_PRIVATE_KEY, ATLAS_FEED_IDS (decimal IDs separated
 * by commas), ATLAS_MAX_PRICE_AGE (positive seconds for deployment preflight).
 * No default feed list: deploying the full registry must be an explicit choice.
 *
 * Dry run (add --broadcast --slow only for an approved deployment):
 * forge script script/oracle/deployAtlasMultiFeedAdaptors.sol:DeployAtlasMultiFeedAdaptors --rpc-url bsc
 */
contract DeployAtlasMultiFeedAdaptors is Script {
  address public constant ATLAS_MULTI_FEED = 0xEAcE519ebB14fB8404fA6DdD23C3b34abaDE44aa;

  function run() public returns (AtlasMultiFeedAdaptor[] memory adaptors) {
    uint256[] memory ids = vm.envUint("ATLAS_FEED_IDS", ",");
    uint256 maxPriceAge = vm.envUint("ATLAS_MAX_PRICE_AGE");
    return _deploy(ids, maxPriceAge, vm.envUint("DEPLOYER_PRIVATE_KEY"));
  }

  function _deploy(
    uint256[] memory ids,
    uint256 maxPriceAge,
    uint256 deployerPrivateKey
  ) internal returns (AtlasMultiFeedAdaptor[] memory adaptors) {
    require(block.chainid == 56, "AtlasMultiFeedDeploy/not-bsc");
    require(ids.length != 0, "AtlasMultiFeedDeploy/empty-feeds");
    require(maxPriceAge != 0, "AtlasMultiFeedDeploy/zero-max-age");
    // This script targets the public BNB Chain registry. Whitelist-only sources
    // need a separate deployment/access plan for the actual adaptor addresses.
    require(IAtlasMultiFeed(ATLAS_MULTI_FEED).isOpenRead(), "AtlasMultiFeedDeploy/not-open-read");

    for (uint256 i; i < ids.length; ++i) {
      require(ids[i] <= type(uint32).max, "AtlasMultiFeedDeploy/feed-id-overflow");
      for (uint256 j; j < i; ++j) {
        require(ids[i] != ids[j], "AtlasMultiFeedDeploy/duplicate-feed");
      }
    }

    adaptors = new AtlasMultiFeedAdaptor[](ids.length);
    vm.startBroadcast(deployerPrivateKey);
    for (uint256 i; i < ids.length; ++i) {
      adaptors[i] = new AtlasMultiFeedAdaptor(ATLAS_MULTI_FEED, bytes4(uint32(ids[i])));
    }
    vm.stopBroadcast();

    // Validate deployed contract calls, not EOA/constructor-only access. Foundry
    // runs these checks in the dry run before broadcasting the deployment batch.
    for (uint256 i; i < ids.length; ++i) {
      (, int256 answer, , uint256 updatedAt, ) = adaptors[i].latestRoundData();
      require(block.timestamp - updatedAt <= maxPriceAge, "AtlasMultiFeedDeploy/stale-price");
      console.log("Feed ID:", ids[i]);
      console.log("Adaptor:", address(adaptors[i]));
      console.log("USD price (8 decimals):", uint256(answer));
      console.log("Aggregated at:", updatedAt);
    }
  }
}
