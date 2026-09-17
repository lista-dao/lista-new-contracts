// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import { AtlasMultiFeedAdaptor } from "@src/oracle/AtlasMultiFeedAdaptor.sol";
import { IAtlasMultiFeed } from "@src/oracle/interfaces/IAtlasMultiFeed.sol";

contract MockAtlasMultiFeed is IAtlasMultiFeed {
  uint8 public decimals = 18;
  uint256 public contractType = 2;
  bool public isOpenRead = true;
  bool public failReads;
  address public authorizedCaller;
  mapping(bytes4 => PriceSnapshot) private snapshots;

  function setSnapshot(bytes4 id, uint80 price, uint48 aggregatedTs, uint48 onchainTs) external {
    snapshots[id] = PriceSnapshot(price, aggregatedTs, onchainTs);
  }

  function setDecimals(uint8 value) external {
    decimals = value;
  }

  function setContractType(uint256 value) external {
    contractType = value;
  }

  function setAccess(bool open, address caller) external {
    isOpenRead = open;
    authorizedCaller = caller;
  }

  function setFailReads(bool value) external {
    failReads = value;
  }

  function fetch(bytes4 id) external view returns (PriceSnapshot memory) {
    require(!failReads, "MockAtlas/unavailable");
    require(isOpenRead || msg.sender == authorizedCaller, "MockAtlas/unauthorized");
    return snapshots[id];
  }
}

contract AtlasMultiFeedAdaptorTest is Test {
  bytes4 private constant FEED_ID = bytes4(uint32(933));
  uint80 private constant RAW_PRICE = 369165197517953797760;
  MockAtlasMultiFeed private source;
  AtlasMultiFeedAdaptor private adaptor;

  function setUp() public {
    vm.warp(1_800_000_000);
    source = new MockAtlasMultiFeed();
    source.setSnapshot(FEED_ID, RAW_PRICE, uint48(block.timestamp - 60), uint48(block.timestamp - 5));
    adaptor = new AtlasMultiFeedAdaptor(address(source), FEED_ID);
  }

  function test_metadataAndLatestRound() public view {
    assertEq(address(adaptor.multiFeed()), address(source));
    assertEq(adaptor.feedId(), FEED_ID);
    assertEq(adaptor.decimals(), 8);
    assertEq(adaptor.description(), "Atlas MultiFeed 0x000003a5");
    assertEq(adaptor.version(), 1);
    (uint80 round, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = adaptor
      .latestRoundData();
    assertEq(answer, 36_916_519_751);
    assertEq(answer, adaptor.latestAnswer());
    assertEq(startedAt, block.timestamp - 60);
    assertEq(updatedAt, block.timestamp - 60);
    assertEq(round, 0);
    assertEq(answeredInRound, 0);
  }

  function test_differentAdaptorsReadTheirFixedFeed() public {
    bytes4 otherId = bytes4(uint32(934));
    source.setSnapshot(otherId, 224e18, uint48(block.timestamp), uint48(block.timestamp));
    AtlasMultiFeedAdaptor other = new AtlasMultiFeedAdaptor(address(source), otherId);
    assertEq(other.latestAnswer(), 224e8);
    assertEq(adaptor.latestAnswer(), 36_916_519_751);
  }

  function testFuzz_scalingNeverOverflows(uint80 rawPrice) public {
    rawPrice = uint80(bound(rawPrice, 1e10, type(uint80).max));
    source.setSnapshot(FEED_ID, rawPrice, uint48(block.timestamp), uint48(block.timestamp));
    assertEq(uint256(adaptor.latestAnswer()), uint256(rawPrice) / 1e10);
  }

  function test_rejectsZeroAddressAndEOA() public {
    vm.expectRevert(AtlasMultiFeedAdaptor.InvalidSource.selector);
    new AtlasMultiFeedAdaptor(address(0), FEED_ID);
    vm.expectRevert(AtlasMultiFeedAdaptor.InvalidSource.selector);
    new AtlasMultiFeedAdaptor(address(0x1234), FEED_ID);
  }

  function test_rejectsWrongContractType() public {
    source.setContractType(1);
    vm.expectRevert(AtlasMultiFeedAdaptor.InvalidContractType.selector);
    new AtlasMultiFeedAdaptor(address(source), FEED_ID);
  }

  function test_rejectsWrongDecimalsAtDeploymentAndAfterSourceUpgrade() public {
    source.setDecimals(8);
    vm.expectRevert(AtlasMultiFeedAdaptor.InvalidDecimals.selector);
    new AtlasMultiFeedAdaptor(address(source), FEED_ID);
    _expectInvalid(AtlasMultiFeedAdaptor.InvalidDecimals.selector);
  }

  function test_rejectsUnknownFeed() public {
    AtlasMultiFeedAdaptor unknown = new AtlasMultiFeedAdaptor(address(source), bytes4(uint32(999)));
    vm.expectRevert(AtlasMultiFeedAdaptor.InvalidPrice.selector);
    unknown.latestRoundData();
  }

  function test_rejectsZeroAndRoundedDownPrice() public {
    source.setSnapshot(FEED_ID, 0, uint48(block.timestamp), uint48(block.timestamp));
    _expectInvalid(AtlasMultiFeedAdaptor.InvalidPrice.selector);
    source.setSnapshot(FEED_ID, 1e10 - 1, uint48(block.timestamp), uint48(block.timestamp));
    _expectInvalid(AtlasMultiFeedAdaptor.InvalidPrice.selector);
    source.setSnapshot(FEED_ID, 1e10, uint48(block.timestamp), uint48(block.timestamp));
    assertEq(adaptor.latestAnswer(), 1);
  }

  function test_rejectsMissingTimestamps() public {
    source.setSnapshot(FEED_ID, RAW_PRICE, 0, uint48(block.timestamp));
    _expectInvalid(AtlasMultiFeedAdaptor.InvalidTimestamp.selector);
    source.setSnapshot(FEED_ID, RAW_PRICE, uint48(block.timestamp), 0);
    _expectInvalid(AtlasMultiFeedAdaptor.InvalidTimestamp.selector);
  }

  function test_rejectsFutureAndReversedTimestamps() public {
    source.setSnapshot(FEED_ID, RAW_PRICE, uint48(block.timestamp + 1), uint48(block.timestamp + 1));
    _expectInvalid(AtlasMultiFeedAdaptor.InvalidTimestamp.selector);
    source.setSnapshot(FEED_ID, RAW_PRICE, uint48(block.timestamp), uint48(block.timestamp + 1));
    _expectInvalid(AtlasMultiFeedAdaptor.InvalidTimestamp.selector);
    source.setSnapshot(FEED_ID, RAW_PRICE, uint48(block.timestamp), uint48(block.timestamp - 1));
    _expectInvalid(AtlasMultiFeedAdaptor.InvalidTimestamp.selector);
  }

  function test_oldAggregationIsNotRefreshedByRepublicationOrReading() public {
    uint48 oldAggregation = uint48(block.timestamp - 1 days);
    source.setSnapshot(FEED_ID, RAW_PRICE, oldAggregation, uint48(block.timestamp));
    vm.warp(block.timestamp + 1 hours);
    (, , , uint256 updatedAt, ) = adaptor.latestRoundData();
    assertEq(updatedAt, oldAggregation);
    // The downstream ResilientOracle, not this adaptor, applies its configured max age.
    assertGt(adaptor.latestAnswer(), 0);
  }

  function test_sourceMustAuthorizeAdaptorNotItsUser() public {
    address user = address(0x1234);
    source.setAccess(false, user);
    vm.expectRevert("MockAtlas/unauthorized");
    vm.prank(user);
    adaptor.latestAnswer();
    source.setAccess(false, address(adaptor));
    assertGt(adaptor.latestAnswer(), 0);
  }

  function test_sourceFailurePropagates() public {
    source.setFailReads(true);
    vm.expectRevert("MockAtlas/unavailable");
    adaptor.latestRoundData();
  }

  function test_historicalRoundsRevert() public {
    vm.expectRevert(AtlasMultiFeedAdaptor.HistoricalRoundsUnsupported.selector);
    adaptor.getRoundData(1);
  }

  function _expectInvalid(bytes4 selector) internal {
    vm.expectRevert(selector);
    adaptor.latestAnswer();
    vm.expectRevert(selector);
    adaptor.latestRoundData();
  }
}
