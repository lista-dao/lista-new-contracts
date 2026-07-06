// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import { LisAsterPriceFeed } from "@src/oracle/LisAsterPriceFeed.sol";
import "@src/oracle/interfaces/OracleInterface.sol";

contract LisAsterPriceFeedTest is Test {
  LisAsterPriceFeed feed;

  address constant RESILIENT_ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address constant ASTER = 0x000Ae314E2A2172a039B26378814C252734f556A;

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.binance.org");
    feed = new LisAsterPriceFeed();
  }

  function test_metadata() public {
    assertEq(feed.decimals(), 8);
    assertEq(feed.version(), 1);
    assertEq(feed.description(), "lisAster / USD");
    assertEq(address(feed.RESILIENT_ORACLE()), RESILIENT_ORACLE);
    assertEq(feed.ASTER(), ASTER);
    assertEq(feed.DISCOUNT_BPS(), 8000);
    assertEq(feed.BPS_DENOMINATOR(), 10000);
  }

  function test_latestAnswer_isAsterTimes0_8() public {
    uint256 asterPrice = OracleInterface(RESILIENT_ORACLE).peek(ASTER);
    assertGt(asterPrice, 0, "aster price should be live on fork");

    uint256 expected = (asterPrice * 8000) / 10000;
    assertEq(uint256(feed.latestAnswer()), expected);

    (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = feed
      .latestRoundData();
    assertEq(roundId, 1);
    assertEq(uint256(answer), expected);
    assertEq(startedAt, block.timestamp);
    assertEq(updatedAt, block.timestamp);
    assertEq(answeredInRound, 1);

    console.log("ASTER   (1e8):", asterPrice);
    console.log("lisAster(1e8):", expected);
  }

  function test_derivesFromAsterOnly_mockedSource() public {
    // Overwrite the ASTER peek result and confirm the feed tracks it at exactly 0.8x.
    uint256 mockAster = 1_00000000; // $1.00 @ 8 decimals
    vm.mockCall(RESILIENT_ORACLE, abi.encodeWithSelector(OracleInterface.peek.selector, ASTER), abi.encode(mockAster));

    assertEq(uint256(feed.latestAnswer()), 80000000); // $0.80

    vm.mockCall(
      RESILIENT_ORACLE,
      abi.encodeWithSelector(OracleInterface.peek.selector, ASTER),
      abi.encode(uint256(2_00000000))
    );
    assertEq(uint256(feed.latestAnswer()), 160000000); // $1.60
  }
}
