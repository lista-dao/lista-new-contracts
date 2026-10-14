// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { AsterRewards } from "../../src/lisaster/AsterRewards.sol";

/// @title DeployAsterRewardsMultiOpImplBsc
/// @notice BSC mainnet: deploy the new AsterRewards implementation (logic contract, no proxy) for
///         the multi-operator upgrade. This script ONLY deploys the logic contract; it does NOT
///         touch the proxy or any role/state.
///
///         What the upgrade adds (storage is append-only — slots 0-4 unchanged):
///           - MANAGER-managed operator whitelist (`addOperator` / `removeOperator`).
///           - `notifyRewards(operators, amounts)` pulls `amounts[i]` from each whitelisted
///             `operators[i]`; the fee is skimmed once on the total.
///
///         The actual upgrade is a separate DEFAULT_ADMIN action behind the 24h TimelockController
///         (`0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253`):
///             1. Timelock: schedule -> (24h) -> execute
///                  upgradeToAndCall(<this impl>, abi.encodeCall(AsterRewards.initializeV2, (NEW_OPERATOR)))
///                * initializeV2 is a DEFAULT_ADMIN-gated reinitializer(2) that whitelists the
///                  existing `operator` AND the passed `newOperator`, so `notifyRewards` works
///                  immediately after the upgrade. Call it ATOMICALLY via upgradeToAndCall.
///             2. MANAGER 3/6 Safe (`0x8d38..`): addOperator(<each further ASTER reward source>)
///                for any sources beyond the two seeded at upgrade time.
///
///         PRE-FLIGHT (run before broadcasting): confirm the storage layout is append-only vs the
///         live implementation —
///             forge inspect src/lisaster/AsterRewards.sol:AsterRewards storageLayout
///         slots 0-4 (asterToken / distributor / feeReceiver / feeRate / operator) MUST be
///         byte-for-byte unchanged; `_operators` (5-6) is newly appended. (cf. slisXAUE storage-shift bug.)
///
///         Run: forge script script/lisaster/deploy_asterrewards_multiop_impl_bsc.s.sol:DeployAsterRewardsMultiOpImplBsc \
///                --rpc-url bsc --broadcast --verify -vvvv
contract DeployAsterRewardsMultiOpImplBsc is Script {
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

    // Sanity: the bare implementation reads 0 for the legacy slot-4 getter and holds no operators.
    // A revert/non-zero here means the wrong code shipped.
    require(impl.operator() == address(0), "impl: operator() missing or non-zero");
    require(impl.operatorCount() == 0, "impl: operatorCount non-zero");

    // The second ASTER reward source to seed at upgrade time (alongside the migrated legacy
    // `operator`). Supplied via env so no address is hardcoded.
    address newOperator = vm.envAddress("NEW_OPERATOR");
    require(newOperator != address(0), "NEW_OPERATOR unset");
    bytes memory upgradeCall = abi.encodeCall(AsterRewards.initializeV2, (newOperator));

    console.log("----------------------------------------------------");
    console.log("AsterRewards NEW impl:", address(impl));
    console.log("Upgrade target proxy: ", ASTER_REWARDS_PROXY);
    console.log("Seed newOperator:     ", newOperator);
    console.log("Next: DEFAULT_ADMIN (24h Timelock) upgradeToAndCall(impl, initializeV2 calldata)");
    console.log("initializeV2 calldata:");
    console.logBytes(upgradeCall);
    console.log("Then: MANAGER (3/6 Safe) addOperator(<each further ASTER reward source>)");
  }
}
