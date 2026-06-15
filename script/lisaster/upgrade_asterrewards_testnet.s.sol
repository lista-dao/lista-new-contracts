// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { AsterRewards } from "../../src/lisaster/AsterRewards.sol";

/// @title UpgradeAsterRewardsTestnet
/// @notice BSC testnet: UUPS-upgrade the AsterRewards proxy to the operator/BOT-notify +
///         emergencyWithdraw implementation, then set the operator to the deployer for testing.
///         Deployer holds both DEFAULT_ADMIN (upgrade) and MANAGER (setOperator) on testnet.
///
///         Run: forge script script/lisaster/upgrade_asterrewards_testnet.s.sol:UpgradeAsterRewardsTestnet \
///                --rpc-url bsc_testnet --broadcast -vvvv
contract UpgradeAsterRewardsTestnet is Script {
  address constant PROXY = 0x31c36C0534D760E9375DF9A5EC247e6401a03d86;
  address constant NEW_IMPL = 0xF77dC94e80bf7cDB8bB1BA9593626c74b6bE5AB9;

  function run() public {
    require(block.chainid == 97, "expect BSC testnet (chainId 97)");

    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(pk);

    vm.startBroadcast(pk);
    AsterRewards proxy = AsterRewards(PROXY);
    proxy.upgradeToAndCall(NEW_IMPL, "");
    proxy.setOperator(deployer);
    vm.stopBroadcast();

    console.log("Proxy:     ", PROXY);
    console.log("New impl:  ", NEW_IMPL);
    console.log("operator:  ", proxy.operator());
  }
}
