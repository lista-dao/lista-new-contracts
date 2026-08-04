// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import { wNLPPriceFeed } from "@src/oracle/wNLPPriceFeed.sol";
import "@src/oracle/interfaces/OracleInterface.sol";

/**
 * @dev Fork tests for the generic wNLP price feed.
 *
 * The wNLP-S5B case (nSPCXB, collateral of the nSPCXB / SPCXB whitelist market)
 * is the new deployment. The wNLP-USDT case reproduces the already deployed
 * hardcoded wNLP-USDT feed to prove the generic contract is behaviour-equivalent
 * to that precedent.
 */
contract wNLPPriceFeedTest is Test {
  address constant RESILIENT_ORACLE = 0xf3afD82A4071f272F403dC176916141f44E6c750;

  // wNLP-S5B == nSPCXB, underlying SPCXB
  address constant WNLP_S5B = 0xF27760F7b431aD8cAeE0f4E3062E6140b14E0eBC;
  address constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;

  // Already-live precedent: wNLP-USDT, underlying USDT
  address constant WNLP_USDT = 0xEA5FF211eF700DccC521a1e6501C9fe1B95D8EE7;
  address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
  // The deployed hardcoded feed for wNLP-USDT
  address constant DEPLOYED_WNLP_USDT_FEED = 0xf86155a27B5Cd958732A29829d80017727dE4262;

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.binance.org");
  }

  function _deploy(address wnlp, address underlying, string memory desc) internal returns (wNLPPriceFeed) {
    return new wNLPPriceFeed(RESILIENT_ORACLE, wnlp, underlying, desc);
  }

  // ---------------------------------------------------------------- wNLP-S5B

  function test_S5B_priceMatchesRateTimesUnderlying() public {
    wNLPPriceFeed feed = _deploy(WNLP_S5B, SPCXB, "wNLP-S5B/USD Price Feed");

    uint256 rate = IWNLP(WNLP_S5B).getNlpByWnlp(1e18);
    uint256 underlyingPrice = OracleInterface(RESILIENT_ORACLE).peek(SPCXB);
    assertGt(rate, 0, "rate must be non-zero");
    assertGt(underlyingPrice, 0, "underlying price must be non-zero");

    (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();

    console.log("wNLP-S5B rate (1e18):", rate);
    console.log("SPCXB price (1e8)   :", underlyingPrice);
    console.log("wNLP-S5B price (1e8):", uint256(answer));

    assertEq(uint256(answer), (underlyingPrice * rate) / 1e18, "price != underlying * rate");
    assertEq(uint256(feed.latestAnswer()), uint256(answer), "latestAnswer != latestRoundData");
    assertEq(updatedAt, block.timestamp, "updatedAt should be block.timestamp");
  }

  /// @dev The wrapper accrues, so wNLP is worth at least the underlying, not less.
  function test_S5B_priceAboveUnderlying() public {
    wNLPPriceFeed feed = _deploy(WNLP_S5B, SPCXB, "wNLP-S5B/USD Price Feed");
    uint256 underlyingPrice = OracleInterface(RESILIENT_ORACLE).peek(SPCXB);
    assertGe(uint256(feed.latestAnswer()), underlyingPrice, "wNLP should be >= underlying");
  }

  function test_S5B_metadata() public {
    wNLPPriceFeed feed = _deploy(WNLP_S5B, SPCXB, "wNLP-S5B/USD Price Feed");
    assertEq(feed.decimals(), 8);
    assertEq(feed.version(), 1);
    assertEq(feed.description(), "wNLP-S5B/USD Price Feed");
    assertEq(address(feed.wNLP()), WNLP_S5B);
    assertEq(feed.underlying(), SPCXB);
    assertEq(address(feed.resilientOracle()), RESILIENT_ORACLE);
  }

  // ------------------------------------------- equivalence with the precedent

  /// @dev Same inputs must produce the same output as the deployed hardcoded feed.
  function test_USDT_matchesDeployedHardcodedFeed() public {
    wNLPPriceFeed generic = _deploy(WNLP_USDT, USDT, "wNLP-USDT/USD Price Feed");

    (, int256 genericAnswer, , , ) = generic.latestRoundData();
    (, int256 deployedAnswer, , , ) = AggregatorV3Interface(DEPLOYED_WNLP_USDT_FEED).latestRoundData();

    console.log("generic  wNLP-USDT (1e8):", uint256(genericAnswer));
    console.log("deployed wNLP-USDT (1e8):", uint256(deployedAnswer));

    assertEq(genericAnswer, deployedAnswer, "generic feed must match deployed feed");
    assertEq(generic.decimals(), 8);
  }

  // ---------------------------------------------------------------- negatives

  function test_revertsOnZeroResilientOracle() public {
    vm.expectRevert("wNLPPriceFeed/zero-address");
    new wNLPPriceFeed(address(0), WNLP_S5B, SPCXB, "x");
  }

  function test_revertsOnZeroWNLP() public {
    vm.expectRevert("wNLPPriceFeed/zero-address");
    new wNLPPriceFeed(RESILIENT_ORACLE, address(0), SPCXB, "x");
  }

  function test_revertsOnZeroUnderlying() public {
    vm.expectRevert("wNLPPriceFeed/zero-address");
    new wNLPPriceFeed(RESILIENT_ORACLE, WNLP_S5B, address(0), "x");
  }

  /// @dev An underlying with no ResilientOracle config makes peek revert, so the
  /// feed fails closed rather than reporting a bogus price.
  function test_revertsWhenUnderlyingHasNoOracleConfig() public {
    // NLP-S5B itself is not configured on the ResilientOracle
    address unconfigured = 0x4EE1C93Eb1Ca08f566211fb18A8Dc5c1C6d04939;
    wNLPPriceFeed feed = _deploy(WNLP_S5B, unconfigured, "bad");
    vm.expectRevert();
    feed.latestAnswer();
  }
}
