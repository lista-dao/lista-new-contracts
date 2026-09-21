// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { AggregatorV3Interface } from "./interfaces/OracleInterface.sol";
import { IAtlasMultiFeed } from "./interfaces/IAtlasMultiFeed.sol";

/**
 * @title AtlasMultiFeedAdaptor
 * @notice Wraps one fixed Atlas MultiFeed entry for the existing ResilientOracle.
 * @dev Prices are converted from 18 to 8 decimals, rounding down. Source, feed ID
 * and bStock symbol are set once at deployment; deploy one adaptor per asset. No
 * owner or upgrade mechanism.
 *
 * updatedAt is the off-chain aggregation time, NOT the publication/read time.
 * ResilientOracle must configure a nonzero timeDeltaTolerance to enforce price
 * age. This adaptor rejects invalid snapshots but deliberately sets no max age.
 * It provides latest prices only, not historical Chainlink rounds.
 */
contract AtlasMultiFeedAdaptor is AggregatorV3Interface {
  IAtlasMultiFeed public immutable multiFeed;
  bytes4 public immutable feedId;

  /// @notice bStock symbol this feed prices, e.g. "GPROB/USD". Constructor-only; strings cannot be immutable.
  string public symbol;

  uint256 private constant SCALE_DIVISOR = 1e10;

  error InvalidSource();
  error InvalidContractType();
  error InvalidDecimals();
  error InvalidSymbol();
  error InvalidPrice();
  error InvalidTimestamp();
  error HistoricalRoundsUnsupported();

  constructor(address multiFeed_, bytes4 feedId_, string memory symbol_) {
    if (multiFeed_.code.length == 0) revert InvalidSource();
    if (bytes(symbol_).length == 0) revert InvalidSymbol();
    IAtlasMultiFeed source = IAtlasMultiFeed(multiFeed_);
    if (source.contractType() != 2) revert InvalidContractType();
    if (source.decimals() != 18) revert InvalidDecimals();
    multiFeed = source;
    feedId = feedId_;
    symbol = symbol_;
  }

  function decimals() external pure returns (uint8) {
    return 8;
  }

  function description() external view returns (string memory) {
    return string.concat("Atlas MultiFeed ", Strings.toHexString(uint32(feedId), 4), " ", symbol);
  }

  /// @notice Version of this adaptor, independent of the Atlas implementation.
  function version() external pure returns (uint256) {
    return 1;
  }

  /// @dev Like latestRoundData, this method does not enforce maximum price age.
  function latestAnswer() external view returns (int256) {
    (int256 answer, ) = _read();
    return answer;
  }

  function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
    revert HistoricalRoundsUnsupported();
  }

  /**
   * @dev Zero round IDs are compatibility placeholders, not historical rounds.
   * ResilientOracle consumes only answer and updatedAt. Both timestamps describe
   * the aggregation; onchainTs is checked separately for malformed snapshots.
   */
  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    (answer, updatedAt) = _read();
    return (0, answer, updatedAt, updatedAt, 0);
  }

  function _read() internal view returns (int256 answer, uint256 updatedAt) {
    // Atlas may upgrade its source proxy; never silently apply the wrong scale.
    if (multiFeed.decimals() != 18) revert InvalidDecimals();
    IAtlasMultiFeed.PriceSnapshot memory snapshot = multiFeed.fetch(feedId);
    uint256 scaledPrice = uint256(snapshot.price) / SCALE_DIVISOR;
    if (scaledPrice == 0) revert InvalidPrice();
    if (
      snapshot.aggregatedTs == 0 ||
      snapshot.onchainTs == 0 ||
      snapshot.aggregatedTs > snapshot.onchainTs ||
      snapshot.onchainTs > block.timestamp
    ) revert InvalidTimestamp();

    // uint80 / 1e10 is always safely representable as int256.
    return (int256(scaledPrice), uint256(snapshot.aggregatedTs));
  }
}
