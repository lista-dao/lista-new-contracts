// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./interfaces/OracleInterface.sol";
import "./libraries/FullMath.sol";

/**
 * @title wNLPPriceFeed
 * @author Lista
 * @notice Generic Chainlink-shaped price feed for any Native wNLP-* wrapper.
 * Reads the wNLP/underlying exchange rate from the wNLP contract and the
 * underlying/USD price from the Lista ResilientOracle, returning wNLP/USD in 8
 * decimals.
 * @dev Parameterised form of the hardcoded wNLP-USDT feed: the wNLP token, its
 * underlying and the description are all constructor immutables, so a single
 * implementation serves every wNLP-* token instead of one file per token.
 * Exposes an 8-decimal AggregatorV3Interface so it can be registered as the
 * MAIN oracle of the wNLP token on the ResilientOracle, which reads it via
 * latestRoundData(), mirroring {AtlasOracleAdaptor} and {LisAsterPriceFeed}.
 *
 * Staleness note: the underlying leg is bounded by the underlying's own
 * timeDeltaTolerance inside the ResilientOracle, and peek reverts on an invalid
 * price. The wNLP rate carries no timestamp, so it cannot be freshness-checked
 * here; a frozen rate would be reported as current. Monitor the rate off-chain.
 */
contract wNLPPriceFeed is AggregatorV3Interface {
  /// @notice Lista ResilientOracle providing the underlying USD price (8 decimals) via peek.
  OracleInterface public immutable resilientOracle;
  /// @notice wNLP-* wrapper token (non-upgradeable), source of the wNLP/underlying rate.
  IWNLP public immutable wNLP;
  /// @notice The wrapper's underlying token, priced by the ResilientOracle.
  address public immutable underlying;

  string private _description;

  /**
   * @param _resilientOracle Lista ResilientOracle address.
   * @param _wNLP wNLP-* wrapper token address.
   * @param _underlying The wrapper's underlying token address.
   * @param description_ Feed description, e.g. "wNLP-S5B/USD Price Feed".
   */
  constructor(address _resilientOracle, address _wNLP, address _underlying, string memory description_) {
    require(
      _resilientOracle != address(0) && _wNLP != address(0) && _underlying != address(0),
      "wNLPPriceFeed/zero-address"
    );
    resilientOracle = OracleInterface(_resilientOracle);
    wNLP = IWNLP(_wNLP);
    underlying = _underlying;
    _description = description_;
  }

  function decimals() external pure returns (uint8) {
    return 8;
  }

  /// @dev `view` rather than `pure` because the description is set per deployment.
  function description() external view returns (string memory) {
    return _description;
  }

  function version() external pure returns (uint256) {
    return 1;
  }

  function latestAnswer() external view returns (int256) {
    return int256(_price());
  }

  function getRoundData(
    uint80 _roundId
  )
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    return (_roundId, int256(_price()), block.timestamp, block.timestamp, _roundId);
  }

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    uint256 timestamp = block.timestamp;
    uint80 round = uint80(timestamp);
    return (round, int256(_price()), timestamp, timestamp, round);
  }

  /**
   * @dev Multiply the wNLP/underlying rate (18 decimals) by the underlying/USD
   * price (8 decimals) and scale back down by 1e18, yielding wNLP/USD in 8
   * decimals. FullMath.mulDiv avoids intermediate overflow.
   */
  function _price() internal view returns (uint256) {
    uint256 rate = wNLP.getNlpByWnlp(1e18);
    require(rate > 0, "wNLPPriceFeed/rate-not-valid");
    uint256 underlyingPrice = resilientOracle.peek(underlying);
    return FullMath.mulDiv(underlyingPrice, rate, 1e18);
  }
}
