// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import { DeployAtlasMultiFeedAdaptors } from "../../script/oracle/deployAtlasMultiFeedAdaptors.sol";
import { AtlasMultiFeedAdaptor } from "@src/oracle/AtlasMultiFeedAdaptor.sol";
import { MockAtlasMultiFeed } from "./AtlasMultiFeedAdaptor.t.sol";

contract TestableDeployAtlasMultiFeedAdaptors is DeployAtlasMultiFeedAdaptors {
  function deployForTest(uint256[] memory ids, uint256 maxPriceAge) external returns (AtlasMultiFeedAdaptor[] memory) {
    // Public test key; no process-global environment mutations in parallel tests.
    return _deploy(ids, maxPriceAge, 1);
  }
}

contract DeployAtlasMultiFeedAdaptorsTest is Test {
  TestableDeployAtlasMultiFeedAdaptors private deployScript;
  MockAtlasMultiFeed private source;
  uint256[] private ids;

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
    ids.push(933);
    ids.push(934);
  }

  function test_deploysOnlySelectedIds() public {
    AtlasMultiFeedAdaptor[] memory adaptors = deployScript.deployForTest(ids, 300);
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
    deployScript.deployForTest(ids, 300);
  }

  function test_rejectsFeedIdTruncation() public {
    ids[0] = 4294967296;
    vm.expectRevert("AtlasMultiFeedDeploy/feed-id-overflow");
    deployScript.deployForTest(ids, 300);
  }

  function test_rejectsDuplicateFeeds() public {
    ids[1] = 933;
    vm.expectRevert("AtlasMultiFeedDeploy/duplicate-feed");
    deployScript.deployForTest(ids, 300);
  }

  function test_requiresPositiveDeploymentMaxAge() public {
    vm.expectRevert("AtlasMultiFeedDeploy/zero-max-age");
    deployScript.deployForTest(ids, 0);
  }

  function test_rejectsWhitelistOnlyRegistry() public {
    source.setAccess(false, address(0));
    vm.expectRevert("AtlasMultiFeedDeploy/not-open-read");
    deployScript.deployForTest(ids, 300);
  }

  function test_rejectsRepublishedStalePrice() public {
    source.setSnapshot(bytes4(uint32(933)), 369e18, uint48(block.timestamp - 301), uint48(block.timestamp));
    vm.expectRevert("AtlasMultiFeedDeploy/stale-price");
    deployScript.deployForTest(ids, 300);
  }

  function test_rejectsUninitializedFeed() public {
    ids[0] = 999;
    vm.expectRevert(AtlasMultiFeedAdaptor.InvalidPrice.selector);
    deployScript.deployForTest(ids, 300);
  }

  function test_rejectsEmptyFeedList() public {
    vm.expectRevert("AtlasMultiFeedDeploy/empty-feeds");
    deployScript.deployForTest(new uint256[](0), 300);
  }
}
