// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "../interfaces/OracleInterface.sol";
import "../libraries/FullMath.sol";

/**
 * @dev Minimal ERC-4626 surface of Sky's sUSDS vault. Declared here rather than in
 * the shared {OracleInterface} file because it is specific to this feed.
 */
interface ISUSDS {
  function convertToAssets(uint256 shares) external view returns (uint256 assets);

  function asset() external view returns (address);
}

/**
 * @title sUSDSPriceFeed
 * @author Lista
 * @notice Chainlink-shaped price feed for Sky's sUSDS (Savings USDS) on Ethereum
 * mainnet. Reads the sUSDS/USDS exchange rate straight from the ERC-4626 vault
 * (`convertToAssets`) and the USDS/USD price from the Lista ResilientOracle
 * (`peek`, 8 decimals), returning sUSDS/USD in 8 decimals.
 *
 * @dev 8-decimal `AggregatorV3Interface`, to be registered as sUSDS's MAIN oracle
 * on the ResilientOracle. Addresses are constants and there is no admin.
 * The sUSDS rate has no timestamp, so only the USDS leg is staleness-checked.
 */
contract sUSDSPriceFeed is AggregatorV3Interface {
  /// @notice Lista ResilientOracle providing the USDS USD price (8 decimals) via `peek`.
  OracleInterface public immutable resilientOracle;

  /// @notice Sky sUSDS (Savings USDS), the ERC-4626 vault providing the sUSDS/USDS rate.
  ISUSDS public constant SUSDS = ISUSDS(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);

  /// @notice USDS, the vault's underlying asset, priced by the ResilientOracle.
  address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

  /**
   * @param _resilientOracle Lista ResilientOracle address (Ethereum mainnet).
   */
  constructor(address _resilientOracle) {
    require(_resilientOracle != address(0), "sUSDSPriceFeed/zero-address");
    require(SUSDS.asset() == USDS, "sUSDSPriceFeed/asset-mismatch");
    resilientOracle = OracleInterface(_resilientOracle);
  }

  function decimals() external pure returns (uint8) {
    return 8;
  }

  function description() external pure returns (string memory) {
    return "sUSDS/USD Price Feed";
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
   * @dev Multiply the sUSDS/USDS rate (18 decimals, USDS per 1 sUSDS) by the
   * USDS/USD price (8 decimals) and scale back down by 1e18, yielding sUSDS/USD
   * in 8 decimals. FullMath.mulDiv avoids intermediate overflow.
   */
  function _price() internal view returns (uint256) {
    uint256 rate = SUSDS.convertToAssets(1e18);
    require(rate > 0, "sUSDSPriceFeed/rate-not-valid");
    uint256 usdsPrice = resilientOracle.peek(USDS);
    return FullMath.mulDiv(usdsPrice, rate, 1e18);
  }
}
