// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

/**
 * @notice Read surface used by the Atlas multi-feed adaptor and deployment script.
 * @dev Subset of https://github.com/oracle-atlas/push-oracle-interfaces/blob/main/src/IMultiFeed.sol.
 */
interface IAtlasMultiFeed {
  struct PriceSnapshot {
    uint80 price;
    uint48 aggregatedTs;
    uint48 onchainTs;
  }

  function contractType() external view returns (uint256);

  function decimals() external view returns (uint8);

  function isOpenRead() external view returns (bool);

  function fetch(bytes4 feedId) external view returns (PriceSnapshot memory);
}
