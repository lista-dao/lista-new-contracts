// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { AsterRewards } from "../../src/lisaster/AsterRewards.sol";

/// @title DeployAsterRewardsImplTestnet
/// @notice Deploys the new AsterRewards implementation (logic contract, no proxy) to BSC testnet,
///         so the operator/BOT-notify + emergencyWithdraw upgrade can be tested before mainnet.
///
///         Run: forge script script/lisaster/deploy_asterrewards_impl_testnet.s.sol:DeployAsterRewardsImplTestnet \
///                --rpc-url bsc_testnet --broadcast --verify -vvvv
contract DeployAsterRewardsImplTestnet is Script {
  function run() public {
    require(block.chainid == 97, "expect BSC testnet (chainId 97)");

    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(pk);
    console.log("Chain ID:        ", block.chainid);
    console.log("Deployer:        ", deployer);

    vm.startBroadcast(pk);
    AsterRewards impl = new AsterRewards();
    vm.stopBroadcast();

    console.log("AsterRewards impl (testnet):", address(impl));
  }
}
