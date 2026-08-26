// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import { sUSDSPriceFeed, ISUSDS } from "@src/oracle/priceFeed/sUSDSPriceFeed.sol";
import "@src/oracle/interfaces/OracleInterface.sol";

/**
 * @dev Fork tests for the sUSDS/USD price feed on Ethereum mainnet.
 *
 * sUSDS is Sky's ERC-4626 savings vault over USDS, so the sUSDS/USDS leg comes
 * straight from `convertToAssets` rather than a Chainlink feed. The USDS/USD leg
 * comes from the Lista ResilientOracle, which is already configured for USDS but
 * not yet for sUSDS - this feed is what makes `peek(sUSDS)` resolve once it is
 * registered as sUSDS's MAIN oracle.
 */
contract sUSDSPriceFeedTest is Test {
  // Lista ResilientOracle (Ethereum mainnet)
  address constant RESILIENT_ORACLE = 0xA64FE284EB8279B9b63946DD51813b0116099301;
  address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
  address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

  sUSDSPriceFeed feed;

  function setUp() public {
    vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    feed = new sUSDSPriceFeed(RESILIENT_ORACLE);
  }

  function test_priceMatchesRateTimesUnderlying() public {
    uint256 rate = ISUSDS(SUSDS).convertToAssets(1e18);
    uint256 usdsPrice = OracleInterface(RESILIENT_ORACLE).peek(USDS);
    assertGt(rate, 0, "rate must be non-zero");
    assertGt(usdsPrice, 0, "USDS price must be non-zero");

    (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();

    console.log("sUSDS/USDS rate (1e18):", rate);
    console.log("USDS price (1e8)      :", usdsPrice);
    console.log("sUSDS price (1e8)     :", uint256(answer));

    assertEq(uint256(answer), (usdsPrice * rate) / 1e18, "price != USDS * rate");
    assertEq(uint256(feed.latestAnswer()), uint256(answer), "latestAnswer != latestRoundData");
    assertEq(updatedAt, block.timestamp, "updatedAt should be block.timestamp");
  }

  /// @dev The vault only accrues, so sUSDS is worth at least one USDS, never less.
  function test_priceAboveUnderlying() public {
    uint256 usdsPrice = OracleInterface(RESILIENT_ORACLE).peek(USDS);
    assertGe(uint256(feed.latestAnswer()), usdsPrice, "sUSDS should be >= USDS");
  }

  /// @dev sUSDS trades near 1 USD; a wildly out-of-band answer means a broken leg.
  function test_priceWithinSaneBand() public view {
    uint256 price = uint256(feed.latestAnswer());
    assertGt(price, 1e8, "sUSDS should be worth more than 1 USD");
    assertLt(price, 5e8, "sUSDS price implausibly high");
  }

  /// @dev The rate accrues with time, so the reported price must rise with it. The
  /// USDS leg is pinned to 1e8 because warping a year forward makes the real
  /// ResilientOracle price stale, which correctly reverts and would mask the rate.
  function test_priceIncreasesOverTime() public {
    vm.mockCall(
      RESILIENT_ORACLE,
      abi.encodeWithSelector(OracleInterface.peek.selector, USDS),
      abi.encode(uint256(1e8))
    );
    uint256 priceNow = uint256(feed.latestAnswer());
    vm.warp(block.timestamp + 365 days);
    uint256 priceLater = uint256(feed.latestAnswer());
    console.log("sUSDS now (1e8):", priceNow);
    console.log("sUSDS +1y (1e8):", priceLater);
    assertGt(priceLater, priceNow, "price should accrue over time");
  }

  function test_getRoundDataEchoesRoundId() public view {
    (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = feed.getRoundData(
      42
    );
    assertEq(roundId, 42);
    assertEq(answeredInRound, 42);
    assertEq(answer, feed.latestAnswer());
    assertEq(startedAt, block.timestamp);
    assertEq(updatedAt, block.timestamp);
  }

  function test_metadata() public view {
    assertEq(feed.decimals(), 8);
    assertEq(feed.version(), 1);
    assertEq(feed.description(), "sUSDS/USD Price Feed");
    assertEq(address(feed.SUSDS()), SUSDS);
    assertEq(feed.USDS(), USDS);
    assertEq(address(feed.resilientOracle()), RESILIENT_ORACLE);
    assertEq(ISUSDS(SUSDS).asset(), USDS, "sUSDS underlying must be USDS");
  }

  // ---------------------------------------------------------------- negatives

  function test_revertsOnZeroResilientOracle() public {
    vm.expectRevert("sUSDSPriceFeed/zero-address");
    new sUSDSPriceFeed(address(0));
  }

  /// @dev If the USDS leg goes bad, the feed reverts instead of reporting a bogus price.
  function test_revertsWhenUSDSPeekReverts() public {
    vm.mockCallRevert(
      RESILIENT_ORACLE,
      abi.encodeWithSelector(OracleInterface.peek.selector, USDS),
      "invalid resilient oracle price"
    );
    vm.expectRevert("invalid resilient oracle price");
    feed.latestAnswer();
  }

  /// @dev A zero exchange rate from the vault must fail closed, not price sUSDS at 0.
  function test_revertsOnZeroRate() public {
    vm.mockCall(SUSDS, abi.encodeWithSelector(ISUSDS.convertToAssets.selector, 1e18), abi.encode(uint256(0)));
    vm.expectRevert("sUSDSPriceFeed/rate-not-valid");
    feed.latestAnswer();
  }
}
