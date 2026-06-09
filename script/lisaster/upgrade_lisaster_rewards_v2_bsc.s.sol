// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { AsterRewards } from "../../src/lisaster/AsterRewards.sol";

/// @title UpgradeAsterRewardsV2Bsc
/// @notice BSC mainnet upgrade for the AsterRewards v2 proxy: `notifyRewards` becomes BOT-only and
///         pulls from `lisAsterManager`; adds `emergencyWithdraw`. The deployer only deploys the
///         new implementation; the UUPS upgrade and `setLisAsterManager` are ADMIN/MANAGER multisig
///         transactions (this script prints their calldata).
///
///         Run: forge script script/lisaster/upgrade_lisaster_rewards_v2_bsc.s.sol:UpgradeAsterRewardsV2Bsc \
///                --rpc-url bsc --broadcast --verify -vvvv
contract UpgradeAsterRewardsV2Bsc is Script {
  address constant ASTER_REWARDS_V2 = 0x935E18A52E24746fF7b4D307012D8A82C2AB5A23;
  /// @dev DEFAULT_ADMIN multisig (executes upgradeToAndCall).
  address constant ADMIN_MULTISIG = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  /// @dev MANAGER multisig (executes setLisAsterManager).
  address constant MANAGER_MULTISIG = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  function run() public {
    require(block.chainid == 56, "expect BSC mainnet (chainId 56)");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

    vm.startBroadcast(deployerPk);
    AsterRewards newImpl = new AsterRewards();
    vm.stopBroadcast();

    bytes memory upgradeCall = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), bytes(""));

    console.log("New AsterRewards impl:   ", address(newImpl));
    console.log("");
    console.log("==== Step 1: ADMIN multisig tx ====");
    console.log("from:", ADMIN_MULTISIG);
    console.log("to:  ", ASTER_REWARDS_V2);
    console.log('data (upgradeToAndCall(newImpl, "")):');
    console.logBytes(upgradeCall);
    console.log("");
    console.log("==== Step 2: MANAGER multisig tx ====");
    console.log("from:", MANAGER_MULTISIG);
    console.log("to:  ", ASTER_REWARDS_V2);
    console.log("call: setLisAsterManager(<lisAsterManager EOA / funding vault>)");
    console.log("(fill the address, then the funding vault approves ASTER to the proxy)");
  }
}
