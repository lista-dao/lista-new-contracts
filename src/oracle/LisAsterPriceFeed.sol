// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./interfaces/OracleInterface.sol";
import "./libraries/FullMath.sol";

/**
 * @title LisAsterPriceFeed
 * @author Lista
 * @notice Non-upgradable price feed for lisAster.
 *
 * The lisAster main price source is derived purely from the ASTER price with a
 * fixed haircut: `lisAster = ASTER * 0.8`. It deliberately does NOT read the
 * lisAster secondary-market price. The ASTER price is sourced from the Lista
 * ResilientOracle (`peek`), which returns an 8-decimal USD price and enforces
 * its own staleness / bound validation upstream.
 *
 * @dev Exposes an 8-decimal `AggregatorV3Interface` so it can be plugged into a
 * downstream ResilientOracle as lisAster's main feed, mirroring
 * {AtlasOracleAdaptor}. Both dependency addresses are hardcoded immutables and
 * the contract has no admin, so the discount ratio and price source can never
 * be changed after deployment.
 */
contract LisAsterPriceFeed is AggregatorV3Interface {
  /// @notice Lista ResilientOracle providing the ASTER USD price (8 decimals) via `peek`.
  OracleInterface public constant RESILIENT_ORACLE = OracleInterface(0xf3afD82A4071f272F403dC176916141f44E6c750);

  /// @notice ASTER token address used as the `peek` key into the ResilientOracle.
  address public constant ASTER = 0x000Ae314E2A2172a039B26378814C252734f556A;

  /// @notice Fixed lisAster discount, expressed in basis points (8000 = 80%).
  uint256 public constant DISCOUNT_BPS = 8000;
  /// @notice Basis-point denominator.
  uint256 public constant BPS_DENOMINATOR = 10000;

  function decimals() external pure returns (uint8) {
    return 8;
  }

  function description() external pure returns (string memory) {
    return "lisAster / USD";
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
    return (1, int256(_price()), block.timestamp, block.timestamp, 1);
  }

  /**
   * @dev Fetch the ASTER price from the ResilientOracle and apply the fixed 0.8
   * discount. `peek` returns an 8-decimal USD price and reverts / returns 0 on an
   * invalid price; the multiplication preserves the 8-decimal scale. FullMath is
   * used to avoid intermediate overflow, though it cannot occur at realistic prices.
   */
  function _price() internal view returns (uint256) {
    uint256 asterPrice = RESILIENT_ORACLE.peek(ASTER);
    return FullMath.mulDiv(asterPrice, DISCOUNT_BPS, BPS_DENOMINATOR);
  }
}
