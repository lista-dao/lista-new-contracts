// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import { DeployAtlasMultiFeedAdaptors } from "../../script/oracle/deployAtlasMultiFeedAdaptors.sol";
import { AtlasMultiFeedAdaptor } from "@src/oracle/AtlasMultiFeedAdaptor.sol";
import { MockAtlasMultiFeed } from "./AtlasMultiFeedAdaptor.t.sol";

contract TestableDeployAtlasMultiFeedAdaptors is DeployAtlasMultiFeedAdaptors {
  function deployForTest(Feed[] memory feeds) external returns (AtlasMultiFeedAdaptor[] memory) {
    // Public test key; no process-global environment mutations in parallel tests.
    return _deploy(feeds, 1);
  }
}

contract DeployAtlasMultiFeedAdaptorsTest is Test {
  TestableDeployAtlasMultiFeedAdaptors private deployScript;
  MockAtlasMultiFeed private source;

  // 60s heartbeat + the 300s buffer = the 360s deployment preflight limit these tests assert on.
  uint32 private constant HEARTBEAT = 60;
  uint256 private constant MAX_PRICE_AGE = 360;

  function setUp() public {
    vm.chainId(56);
    vm.warp(1_800_000_000);
    deployScript = new TestableDeployAtlasMultiFeedAdaptors();
    MockAtlasMultiFeed template = new MockAtlasMultiFeed();
    vm.etch(deployScript.ATLAS_MULTI_FEED(), address(template).code);
    source = MockAtlasMultiFeed(deployScript.ATLAS_MULTI_FEED());
    source.setDecimals(18);
    source.setContractType(2);
    source.setAccess(true, address(0));
    source.setSnapshot(bytes4(uint32(933)), 369e18, uint48(block.timestamp), uint48(block.timestamp));
    source.setSnapshot(bytes4(uint32(934)), 224e18, uint48(block.timestamp), uint48(block.timestamp));
  }

  function _feeds() private pure returns (DeployAtlasMultiFeedAdaptors.Feed[] memory feeds) {
    feeds = new DeployAtlasMultiFeedAdaptors.Feed[](2);
    feeds[0] = DeployAtlasMultiFeedAdaptors.Feed("TSLAB/USD", 933, HEARTBEAT);
    feeds[1] = DeployAtlasMultiFeedAdaptors.Feed("NVDAB/USD", 934, HEARTBEAT);
  }

  function test_deploysOnlySelectedIds() public {
    AtlasMultiFeedAdaptor[] memory adaptors = deployScript.deployForTest(_feeds());
    assertEq(adaptors.length, 2);
    assertTrue(address(adaptors[0]) != address(adaptors[1]));
    assertEq(address(adaptors[0].multiFeed()), address(source));
    assertEq(adaptors[0].feedId(), bytes4(uint32(933)));
    assertEq(adaptors[1].feedId(), bytes4(uint32(934)));
    assertEq(adaptors[0].latestAnswer(), 369e8);
    assertEq(adaptors[1].latestAnswer(), 224e8);
  }

  function test_rejectsWrongChain() public {
    vm.chainId(1);
    vm.expectRevert("AtlasMultiFeedDeploy/not-bsc");
    deployScript.deployForTest(_feeds());
  }

  function test_rejectsDuplicateFeeds() public {
    DeployAtlasMultiFeedAdaptors.Feed[] memory feeds = _feeds();
    feeds[1].feedId = 933;
    vm.expectRevert("AtlasMultiFeedDeploy/duplicate-feed");
    deployScript.deployForTest(feeds);
  }

  function test_requiresPositiveHeartbeat() public {
    DeployAtlasMultiFeedAdaptors.Feed[] memory feeds = _feeds();
    feeds[0].heartbeat = 0;
    vm.expectRevert("AtlasMultiFeedDeploy/zero-heartbeat");
    deployScript.deployForTest(feeds);
  }

  function test_rejectsWhitelistOnlyRegistry() public {
    source.setAccess(false, address(0));
    vm.expectRevert("AtlasMultiFeedDeploy/not-open-read");
    deployScript.deployForTest(_feeds());
  }

  function test_rejectsRepublishedStalePrice() public {
    source.setSnapshot(
      bytes4(uint32(933)),
      369e18,
      uint48(block.timestamp - MAX_PRICE_AGE - 1),
      uint48(block.timestamp)
    );
    vm.expectRevert("AtlasMultiFeedDeploy/stale-price");
    deployScript.deployForTest(_feeds());
  }

  function test_acceptsPriceAtMaxAge() public {
    source.setSnapshot(bytes4(uint32(933)), 369e18, uint48(block.timestamp - MAX_PRICE_AGE), uint48(block.timestamp));
    AtlasMultiFeedAdaptor[] memory adaptors = deployScript.deployForTest(_feeds());
    assertEq(adaptors[0].latestAnswer(), 369e8);
  }

  function test_rejectsUninitializedFeed() public {
    DeployAtlasMultiFeedAdaptors.Feed[] memory feeds = _feeds();
    feeds[0].feedId = 999;
    vm.expectRevert(AtlasMultiFeedAdaptor.InvalidPrice.selector);
    deployScript.deployForTest(feeds);
  }

  function test_rejectsEmptyFeedList() public {
    vm.expectRevert("AtlasMultiFeedDeploy/empty-feeds");
    deployScript.deployForTest(new DeployAtlasMultiFeedAdaptors.Feed[](0));
  }
}
