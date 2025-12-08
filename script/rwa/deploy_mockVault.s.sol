// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../../src/mock/MockAsyncVault.sol";

contract DeployMockVault is Script {
  address public USDC = 0x37dd428A109966c42eFcad2e4D233Bd72dc43103;
  address public shareToken = 0xC8C0A2098BE100F7CBBA414c55966F754d851b84;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);
    MockAsyncVault mockVault = new MockAsyncVault(USDC, shareToken, 1e18);
    vm.stopPrank();

    console.log("MockAsyncVault: ", address(mockVault));
  }
}
