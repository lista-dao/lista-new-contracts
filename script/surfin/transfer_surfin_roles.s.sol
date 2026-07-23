// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title TransferSurfinRoles
 * @notice Hands Surfin governance from the deployer (temporary admin/manager) to
 *         production custody on all four proxies (FlexEarnPool, LockedEarnPool,
 *         SurfinAdapter, InterestDistributor):
 *           - DEFAULT_ADMIN_ROLE -> ADMIN (TimeLock; upgrade authority)
 *           - MANAGER            -> MANAGER_MULTISIG (Safe)
 *           - then renounces the deployer's MANAGER + DEFAULT_ADMIN on each.
 *         PAUSER / BOT (and the distributor's FUNDER = adapter) were set to their
 *         final holders at deploy time and are left untouched.
 *
 * @dev Run AFTER deploy + first-cohort setup, signed by the current deployer/admin.
 *      DEFAULT_ADMIN is renounced LAST per contract (the grants above need it). IRREVERSIBLE.
 *
 *      Chain-scoped: fill in the deployed proxy addresses AND the production custody
 *      addresses for the chain you are rotating, then run with that chain's RPC.
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=<key> \
 *     forge script script/surfin/transfer_surfin_roles.s.sol:TransferSurfinRoles \
 *     --rpc-url <bsc|eth> --broadcast -vvvv
 */
contract TransferSurfinRoles is Script {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  /* =========================== BSC mainnet (chainId 56) =========================== */
  // TODO: fill in after deploy_surfin_bsc. Left as address(0) so the run() guard blocks an unset run.
  address constant BSC_FLEX = address(0);
  address constant BSC_LOCKED = address(0);
  address constant BSC_ADAPTER = address(0);
  address constant BSC_DISTRIBUTOR = address(0);
  // TODO: BSC production custody (TimeLock + Safe).
  address constant BSC_ADMIN = address(0);
  address constant BSC_MANAGER_MULTISIG = address(0);

  /* =========================== ETH mainnet (chainId 1) =========================== */
  // TODO: fill in after deploy_surfin_eth. Left as address(0) so the run() guard blocks an unset run.
  address constant ETH_FLEX = address(0);
  address constant ETH_LOCKED = address(0);
  address constant ETH_ADAPTER = address(0);
  address constant ETH_DISTRIBUTOR = address(0);
  // TODO: ETH production custody (TimeLock + Safe).
  address constant ETH_ADMIN = address(0);
  address constant ETH_MANAGER_MULTISIG = address(0);

  function run() public {
    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(pk);

    (address flex, address locked, address adapter, address distributor, address admin, address multisig) = _resolve();

    require(admin != address(0) && multisig != address(0), "custody unset");
    require(
      flex != address(0) && locked != address(0) && adapter != address(0) && distributor != address(0),
      "proxy unset"
    );

    console.log("Chain ID:", block.chainid);
    console.log("Deployer (renouncing):", deployer);
    console.log("DEFAULT_ADMIN ->", admin);
    console.log("MANAGER ->", multisig);

    vm.startBroadcast(pk);
    _rotate(flex, admin, multisig, deployer);
    _rotate(locked, admin, multisig, deployer);
    _rotate(adapter, admin, multisig, deployer);
    _rotate(distributor, admin, multisig, deployer);
    vm.stopBroadcast();

    console.log("Done. Verify per proxy: DEFAULT_ADMIN==ADMIN & count==1; MANAGER==multisig; deployer holds nothing.");
  }

  /// @dev pick the deployed proxies + custody for the current chain.
  function _resolve()
    internal
    view
    returns (address flex, address locked, address adapter, address distributor, address admin, address multisig)
  {
    if (block.chainid == 56) {
      return (BSC_FLEX, BSC_LOCKED, BSC_ADAPTER, BSC_DISTRIBUTOR, BSC_ADMIN, BSC_MANAGER_MULTISIG);
    } else if (block.chainid == 1) {
      return (ETH_FLEX, ETH_LOCKED, ETH_ADAPTER, ETH_DISTRIBUTOR, ETH_ADMIN, ETH_MANAGER_MULTISIG);
    }
    revert("unsupported chain");
  }

  /// @dev grant new custody, then renounce the deployer. DEFAULT_ADMIN renounced LAST.
  function _rotate(address proxy, address timelock, address multisig, address deployer) internal {
    IAccessControl ac = IAccessControl(proxy);
    ac.grantRole(MANAGER, multisig);
    ac.grantRole(DEFAULT_ADMIN_ROLE, timelock);
    ac.renounceRole(MANAGER, deployer);
    ac.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
  }
}
