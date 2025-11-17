// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/VaultDistributor.sol";

contract VaultDistributorScript is Script {
  address lpToken = 0x02A5ca3a749855d1002A78813E679584a96646d0;
  address USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
  address bot = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  address pauser = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address manager = 0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    vm.startBroadcast(deployerPrivateKey);
    VaultDistributor impl = new VaultDistributor();
    console.log("Impl: %s", address(impl));

    address[] memory tokens = new address[](1);
    tokens[0] = USD1;

    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, admin, manager, bot, pauser, lpToken, tokens)
    );

    console.log("Proxy: %s", address(proxy));
    vm.stopBroadcast();
  }
}
