// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import { AtlasMultiFeedAdaptor } from "@src/oracle/AtlasMultiFeedAdaptor.sol";
import { IAtlasMultiFeed } from "@src/oracle/interfaces/IAtlasMultiFeed.sol";

interface IResilientOracleAtlasTest {
  struct TokenConfig {
    address asset;
    address[3] oracles;
    bool[3] enableFlagsForOracles;
    uint256 timeDeltaTolerance;
  }

  function owner() external view returns (address);
  function getTokenConfig(address asset) external view returns (TokenConfig memory);
  function setTokenConfig(TokenConfig calldata config) external;
  function getPriceFromOracle(address oracle, uint256 tolerance) external view returns (uint256);
  function peek(address asset) external view returns (uint256);
}

/// @dev Opt in with ATLAS_RUN_FORK_TESTS=true. All mutations stay on the local fork.
contract AtlasMultiFeedAdaptorForkTest is Test {
  address private constant REGISTRY = 0xEAcE519ebB14fB8404fA6DdD23C3b34abaDE44aa;
  address private constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
  IResilientOracleAtlasTest private constant RESILIENT =
    IResilientOracleAtlasTest(0xf3afD82A4071f272F403dC176916141f44E6c750);
  AtlasMultiFeedAdaptor private adaptor;

  function setUp() public {
    vm.skip(!vm.envOr("ATLAS_RUN_FORK_TESTS", false));
    vm.createSelectFork(
      vm.envOr("BSC_RPC", string("https://bsc-dataseed.binance.org")),
      vm.envOr("ATLAS_FORK_BLOCK", uint256(120911148))
    );
    adaptor = new AtlasMultiFeedAdaptor(REGISTRY, bytes4(uint32(938)));
  }

  function testFork_liveSourceAndUnchangedResilientOracle() public {
    assertTrue(IAtlasMultiFeed(REGISTRY).isOpenRead());
    IAtlasMultiFeed.PriceSnapshot memory snapshot = IAtlasMultiFeed(REGISTRY).fetch(bytes4(uint32(938)));
    assertEq(uint256(adaptor.latestAnswer()), uint256(snapshot.price) / 1e10);
    assertEq(RESILIENT.getPriceFromOracle(address(adaptor), 300), uint256(snapshot.price) / 1e10);

    IResilientOracleAtlasTest.TokenConfig memory config = RESILIENT.getTokenConfig(SPCXB);
    assertEq(config.asset, SPCXB);
    config.oracles[0] = address(adaptor);
    config.enableFlagsForOracles = [true, false, false];
    config.timeDeltaTolerance = 300;
    vm.prank(RESILIENT.owner());
    RESILIENT.setTokenConfig(config);
    assertEq(RESILIENT.peek(SPCXB), uint256(snapshot.price) / 1e10);

    vm.warp(uint256(snapshot.aggregatedTs) + 301);
    assertEq(RESILIENT.getPriceFromOracle(address(adaptor), 300), 0);
    vm.expectRevert();
    RESILIENT.peek(SPCXB);
  }

  function testFork_republishedOldPriceStillExpires() public {
    vm.mockCall(
      REGISTRY,
      abi.encodeCall(IAtlasMultiFeed.fetch, (bytes4(uint32(938)))),
      abi.encode(IAtlasMultiFeed.PriceSnapshot(100e18, uint48(block.timestamp - 301), uint48(block.timestamp)))
    );
    assertEq(RESILIENT.getPriceFromOracle(address(adaptor), 300), 0);
  }

  function testFork_sourceFailureBecomesInvalidPrice() public {
    vm.mockCallRevert(REGISTRY, abi.encodeCall(IAtlasMultiFeed.fetch, (bytes4(uint32(938)))), "unavailable");
    assertEq(RESILIENT.getPriceFromOracle(address(adaptor), 300), 0);
  }
}
