// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title TransferRoleSlisXAUEMainnet
 * @notice Hands slisXAUE governance from the deployer (temporary admin/manager) to production custody:
 *         DEFAULT_ADMIN_ROLE -> 24h TimeLock on all three proxies, MANAGER -> ops multisig on staking
 *         + adapter, then renounces the deployer's roles. BOT, PAUSER and MINTER (= XAUTStaking) were
 *         set to their final holders at deploy time and are left untouched.
 *
 * @dev Run AFTER deploy + whitelist + seed deposit. Fill the env vars first:
 *      TIMELOCK_ADDRESS, MANAGER_MULTISIG, SLISXAUE_PROXY, STAKING_PROXY, ADAPTER_PROXY.
 *      DEFAULT_ADMIN is renounced LAST per contract (the grants above need it).
 */
contract TransferRoleSlisXAUEMainnet is Script {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(pk);

    address timelock = vm.envAddress("TIMELOCK_ADDRESS"); // -> DEFAULT_ADMIN_ROLE (all three)
    address managerMs = vm.envAddress("MANAGER_MULTISIG"); // -> MANAGER (staking + adapter)
    address slis = vm.envAddress("SLISXAUE_PROXY");
    address staking = vm.envAddress("STAKING_PROXY");
    address adapter = vm.envAddress("ADAPTER_PROXY");

    require(timelock != address(0) && managerMs != address(0), "zero target");
    require(slis != address(0) && staking != address(0) && adapter != address(0), "zero proxy");

    console.log("Deployer (renouncing): ", deployer);
    console.log("TimeLock (DEFAULT_ADMIN):", timelock);
    console.log("MANAGER multisig:       ", managerMs);

    vm.startBroadcast(pk);

    // SlisXAUE: only DEFAULT_ADMIN (MINTER stays = XAUTStaking).
    IAccessControl(slis).grantRole(DEFAULT_ADMIN_ROLE, timelock);
    IAccessControl(slis).renounceRole(DEFAULT_ADMIN_ROLE, deployer);

    // XAUTStaking: DEFAULT_ADMIN -> TimeLock, MANAGER -> multisig (PAUSER already final).
    IAccessControl(staking).grantRole(MANAGER, managerMs);
    IAccessControl(staking).grantRole(DEFAULT_ADMIN_ROLE, timelock);
    IAccessControl(staking).renounceRole(MANAGER, deployer);
    IAccessControl(staking).renounceRole(DEFAULT_ADMIN_ROLE, deployer);

    // XAUEAdapter: DEFAULT_ADMIN -> TimeLock, MANAGER -> multisig (BOT already final).
    IAccessControl(adapter).grantRole(MANAGER, managerMs);
    IAccessControl(adapter).grantRole(DEFAULT_ADMIN_ROLE, timelock);
    IAccessControl(adapter).renounceRole(MANAGER, deployer);
    IAccessControl(adapter).renounceRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log(
      "Done. Verify each proxy: DEFAULT_ADMIN member==TimeLock & count==1; MANAGER==multisig; deployer holds nothing."
    );
  }
}
