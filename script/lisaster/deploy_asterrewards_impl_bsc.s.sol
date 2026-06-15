// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { AsterRewards } from "../../src/lisaster/AsterRewards.sol";

/// @title DeployAsterRewardsImplBsc
/// @notice BSC mainnet: deploy the new AsterRewards implementation (logic contract, no proxy) for
///         the operator/BOT-notify + emergencyWithdraw upgrade (PR #35). This script ONLY deploys
///         the logic contract; it does NOT touch the proxy or any role/state.
///
///         The actual upgrade is a separate DEFAULT_ADMIN action behind the 24h TimelockController
///         (`0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253`):
///             1. Timelock:  schedule -> (24h) -> execute  upgradeToAndCall(<this impl>, "")
///             2. MANAGER 3/6 Safe (`0x8d38..`): setOperator(AsterVault.lisAsterManager())
///         See the "AsterRewards v2 上线 Runbook" (steps 1–3) for the full multisig flow.
///
///         PRE-FLIGHT (run before broadcasting): confirm the storage layout is append-only vs the
///         live implementation —
///             forge inspect AsterRewards storageLayout
///         slot 0–3 (asterToken / distributor / feeReceiver / feeRate) MUST be byte-for-byte
///         unchanged; only slot 4 (`operator`) is newly appended. (cf. slisXAUE storage-shift bug.)
///
///         Run: forge script script/lisaster/deploy_asterrewards_impl_bsc.s.sol:DeployAsterRewardsImplBsc \
///                --rpc-url bsc --broadcast --verify -vvvv
contract DeployAsterRewardsImplBsc is Script {
  /// @dev Live AsterRewards v2 proxy — the upgrade target. NOT modified by this script; logged for
  ///      hand-off to the Timelock upgrade step.
  address constant ASTER_REWARDS_PROXY = 0x935E18A52E24746fF7b4D307012D8A82C2AB5A23;

  function run() public {
    require(block.chainid == 56, "expect BSC mainnet (chainId 56)");

    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(pk);
    console.log("Chain ID:        ", block.chainid);
    console.log("Deployer:        ", deployer);

    vm.startBroadcast(pk);
    AsterRewards impl = new AsterRewards();
    vm.stopBroadcast();

    // Sanity: the freshly deployed logic must expose operator() (the slot-4 getter added in PR #35)
    // and read 0 on the bare implementation. A revert/non-zero here means the wrong code shipped.
    require(impl.operator() == address(0), "impl: operator() missing or non-zero");

    console.log("----------------------------------------------------");
    console.log("AsterRewards NEW impl:", address(impl));
    console.log("Upgrade target proxy: ", ASTER_REWARDS_PROXY);
    console.log('Next: DEFAULT_ADMIN (24h Timelock) upgradeToAndCall(impl, "")');
    console.log("Then: MANAGER (3/6 Safe) setOperator(AsterVault.lisAsterManager())");
  }
}
