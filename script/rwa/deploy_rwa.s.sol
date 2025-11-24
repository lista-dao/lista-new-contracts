// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/rwa/RWAEarnPool.sol";
import "../../src/rwa/RWAAdapter.sol";

contract DeployRWA is Script {
  address public USDT = 0x55d398326f99059fF775485246999027B3197955;
  address public JTRSYUSDTVault = 0x6e6B8498415083a4386BE83DD59Edd4366402FFa;
  address public JAAAUSDTVault = 0xcbAfe61d84C6Fb88252a6Adf1C9CB0B9D029cb99;
  address public JTRSYUSDTVShareToken = 0xa5d465251fBCc907f5Dd6bB2145488DFC6a2627b;
  address public JAAAUSDTVShareToken = 0x58F93d6b1EF2F44eC379Cb975657C132CBeD3B6b;
  address pauser = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    address admin = deployer;
    address manager = deployer;
    vm.startBroadcast(deployerPrivateKey);
    deployRWA(
      admin,
      manager,
      pauser,
      bot,
      USDT,
      "USDT.Treasury",
      "USDT.Treasury",
      JTRSYUSDTVault,
      JTRSYUSDTVShareToken
    );
    deployRWA(admin, manager, pauser, bot, USDT, "USDT.AAA", "USDT.AAA", JAAAUSDTVault, JAAAUSDTVShareToken);
    vm.stopPrank();
  }

  function deployRWA(
    address admin,
    address manager,
    address pauser,
    address bot,
    address asset,
    string memory name,
    string memory symbol,
    address vault,
    address shareToken
  ) private {
    RWAEarnPool earnPoolImpl = new RWAEarnPool();
    RWAAdapter adapterImpl = new RWAAdapter(asset, asset);

    RWAEarnPool earnPool = RWAEarnPool(address(new ERC1967Proxy(address(earnPoolImpl), "")));

    RWAAdapter adapter = RWAAdapter(address(new ERC1967Proxy(address(adapterImpl), "")));

    earnPool.initialize(admin, manager, pauser, asset, name, symbol, address(adapter));

    adapter.initialize(admin, manager, bot, address(earnPool), vault, shareToken);

    console.log("--------------------------", name, "--------------------------");
    console.log("RWAEarnPool: ", address(earnPool));
    console.log("RWAAdapter: ", address(adapter));
    console.log("-----------------------------------------------------");
  }
}
