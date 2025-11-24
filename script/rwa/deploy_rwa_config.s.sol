// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/rwa/RWAEarnPool.sol";
import "../../src/rwa/RWAAdapter.sol";

contract DeployRWAConfig is Script {
  address earnPool1 = 0x4C78D6aFfb5063Af9af922874B0885Bc3f77d114;
  address adapter1 = 0xc12544BE695b6f5aa0A609ab5a2d80B5AD5170b6;

  address earnPool2 = 0x5Ecf6fD97cEB71c3A6C66BcfCaAF66Aeb28edf43;
  address adapter2 = 0x587b55F3c6Ef0693c93404d1c9B8fE81b2cB7205;

  address withdrawFeeRecipient = 0x2E2Eed557FAb1d2E11fEA1E1a23FF8f1b23551f3;
  address profitFeeRecipient = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  uint256 withdrawFeeRate = 0.001 ether; // 0.1%
  uint256 profitFeeRate = 0.05 ether; // 5%

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);
    RWAEarnPool(earnPool1).setFeeReceiver(withdrawFeeRecipient);
    RWAEarnPool(earnPool1).setWithdrawFeeRate(withdrawFeeRate);
    RWAAdapter(adapter1).setFeeReceiver(profitFeeRecipient);
    RWAAdapter(adapter1).setFeeRate(profitFeeRate);

    RWAEarnPool(earnPool2).setFeeReceiver(withdrawFeeRecipient);
    RWAEarnPool(earnPool2).setWithdrawFeeRate(withdrawFeeRate);
    RWAAdapter(adapter2).setFeeReceiver(profitFeeRecipient);
    RWAAdapter(adapter2).setFeeRate(profitFeeRate);
    vm.stopPrank();
  }
}
