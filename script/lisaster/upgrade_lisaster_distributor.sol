// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { LisAsterDistributor } from "../../src/lisaster/LisAsterDistributor.sol";

/// @title UpgradeLisAsterDistributorTestnet
/// @notice One-shot BSC testnet upgrade for the LisAsterDistributor proxy:
///         1. Deploys a fresh implementation containing the BOT-role + pending-root +
///            waitingPeriod additions.
///         2. UUPS-upgrades the proxy to the new implementation (no reinitializer — newly
///            appended state vars are zero-initialized in storage).
///         3. Wires the new state vars from the admin EOA:
///            - changeWaitingPeriod(6 hours)        [must run BEFORE the BOT grant so that no
///                                                   BOT can ever stage with waitingPeriod=0]
///            - grantRole(BOT, deployer)            [testnet default: deployer holds all roles]
///         All steps require DEFAULT_ADMIN_ROLE; the deployer holds it on testnet.
///         Run: forge script script/lisAster/upgrade_lisaster_distributor.sol:UpgradeLisAsterDistributorTestnet \
///                --rpc-url bsc_testnet --broadcast --verify -vvvv
contract UpgradeLisAsterDistributorTestnet is Script {
  /// @dev BSC testnet LisAsterDistributor proxy.
  address constant DISTRIBUTOR_PROXY = 0xF23511ef5742EF29824F3f7cD265595737947efa;

  /// @dev Pending-root time-lock window. Must be >= LisAsterDistributor.MIN_WAITING_PERIOD (6h).
  uint256 constant DISTRIBUTOR_WAITING_PERIOD = 6 hours;

  function run() public {
    require(block.chainid == 97, "expect BSC testnet (chainId 97)");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPk);

    LisAsterDistributor proxy = LisAsterDistributor(DISTRIBUTOR_PROXY);
    require(proxy.hasRole(proxy.DEFAULT_ADMIN_ROLE(), deployer), "deployer lacks DEFAULT_ADMIN_ROLE");

    console.log("Chain ID:           ", block.chainid);
    console.log("Deployer (admin):   ", deployer);
    console.log("Proxy:              ", DISTRIBUTOR_PROXY);

    vm.startBroadcast(deployerPk);

    // 1. Deploy new implementation.
    LisAsterDistributor newImpl = new LisAsterDistributor();

    // 2. UUPS upgrade. No reinitializer call — appended state vars are already zero, and the
    //    initialize() signature changed but is gated by `initializer` so it cannot run again.
    proxy.upgradeToAndCall(address(newImpl), "");

    // 3. Configure new state. Order: waitingPeriod first, BOT grant second.
    proxy.changeWaitingPeriod(DISTRIBUTOR_WAITING_PERIOD);
    proxy.grantRole(proxy.BOT(), deployer);

    vm.stopBroadcast();

    console.log("---- Post-upgrade ----");
    console.log("New impl:           ", address(newImpl));
    console.log("waitingPeriod (s):  ", proxy.waitingPeriod());
    console.log("BOT holder:         ", deployer);
  }
}
