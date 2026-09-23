// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "../interfaces/OracleInterface.sol";

/**
 * @title OneWeiPriceFeed
 * @author Lista
 * @notice Constant price feed that always answers `1`, the smallest
 * representable value at the feed's 8-decimal scale (i.e. 1e-8 USD).
 *
 * @dev Stateless 8-decimal `AggregatorV3Interface`. There is no price source,
 * no admin and no storage, so the answer can never change and the feed can
 * never go stale: `startedAt` / `updatedAt` are always `block.timestamp`.
 * Intended for assets whose collateral value must be pinned to effectively
 * zero while still satisfying consumers that reject a zero or negative answer.
 */
contract OneWeiPriceFeed is AggregatorV3Interface {
  /// @notice The constant answer returned by every price call.
  int256 public constant PRICE = 1;

  function decimals() external pure returns (uint8) {
    return 8;
  }

  function description() external pure returns (string memory) {
    return "One Wei Price Feed";
  }

  function version() external pure returns (uint256) {
    return 1;
  }

  function latestAnswer() external pure returns (int256) {
    return PRICE;
  }

  function getRoundData(
    uint80 _roundId
  )
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    return (_roundId, PRICE, block.timestamp, block.timestamp, _roundId);
  }

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    return (1, PRICE, block.timestamp, block.timestamp, 1);
  }
}
