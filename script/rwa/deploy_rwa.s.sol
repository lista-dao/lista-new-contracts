// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/rwa/RWAEarnPool.sol";
import "../../src/rwa/RWAAdapter.sol";
import "../../src/rwa/OTCManager.sol";

contract DeployRWA is Script {
  address public USD1 = 0x3189e817d80048321f1809523F1eB75D1cF16020;
  address public USDC = 0x37dd428A109966c42eFcad2e4D233Bd72dc43103;
  address public vault = 0xd6227C734d9f3081520D964cB8B09f0B3386DD80;
  address public shareToken = 0xC8C0A2098BE100F7CBBA414c55966F754d851b84;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    address admin = deployer;
    address manager = deployer;
    address pauser = deployer;
    address bot = deployer;
    address otcWallet = deployer;

    vm.startBroadcast(deployerPrivateKey);

    RWAEarnPool earnPoolImpl = new RWAEarnPool();
    RWAAdapter adapterImpl = new RWAAdapter(USD1, USDC);
    OTCManager otcManagerImpl = new OTCManager(USD1, USDC);

    RWAEarnPool earnPool = RWAEarnPool(address(new ERC1967Proxy(address(earnPoolImpl), "")));

    RWAAdapter adapter = RWAAdapter(address(new ERC1967Proxy(address(adapterImpl), "")));

    OTCManager otcManager = OTCManager(address(new ERC1967Proxy(address(otcManagerImpl), "")));

    earnPool.initialize(admin, manager, pauser, address(USD1), "USD1.Treasury", "USD1.Treasury", address(adapter));

    adapter.initialize(admin, manager, bot, address(earnPool), address(vault), address(shareToken));

    otcManager.initialize(admin, manager, bot, address(adapter), otcWallet);
    vm.stopPrank();

    console.log("RWAEarnPool: ", address(earnPool));
    console.log("RWAAdapter: ", address(adapter));
    console.log("OTCManager: ", address(otcManager));
  }
}
