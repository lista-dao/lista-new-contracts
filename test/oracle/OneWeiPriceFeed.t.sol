// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import { OneWeiPriceFeed } from "@src/oracle/priceFeed/OneWeiPriceFeed.sol";

contract OneWeiPriceFeedTest is Test {
  OneWeiPriceFeed feed;

  function setUp() public {
    feed = new OneWeiPriceFeed();
  }

  function test_metadata() public {
    assertEq(feed.decimals(), 8);
    assertEq(feed.version(), 1);
    assertEq(feed.description(), "One Wei Price Feed");
    assertEq(feed.PRICE(), 1);
  }

  function test_alwaysAnswersOne(uint80 roundId, uint256 ts) public {
    ts = bound(ts, 1, type(uint64).max);
    vm.warp(ts);

    assertEq(feed.latestAnswer(), 1);

    (uint80 rid, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
    assertEq(rid, 1);
    assertEq(answer, 1);
    assertEq(startedAt, ts);
    assertEq(updatedAt, ts);
    assertEq(answeredInRound, 1);

    (rid, answer, startedAt, updatedAt, answeredInRound) = feed.getRoundData(roundId);
    assertEq(rid, roundId);
    assertEq(answer, 1);
    assertEq(startedAt, ts);
    assertEq(updatedAt, ts);
    assertEq(answeredInRound, roundId);
  }
}
