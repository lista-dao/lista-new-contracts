// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title TransferRoleSlisXAUEMainnet
 * @notice Hands slisXAUE governance from the deployer (temporary admin/manager) to production custody:
 *         DEFAULT_ADMIN_ROLE -> ADMIN on all three proxies, MANAGER -> ops multisig on staking +
 *         adapter, then renounces the deployer's roles. BOT, PAUSER and MINTER (= XAUTStaking) were
 *         set to their final holders at deploy time and are left untouched.
 *
 * @dev Run AFTER whitelist + seed deposit, signed by the current deployer/admin (DEPLOYER_PRIVATE_KEY).
 *      DEFAULT_ADMIN is renounced LAST per contract (the grants above need it). IRREVERSIBLE.
 *
 *      WARNING: ADMIN (0x07D274..) is the designated 24h TimeLock for DEFAULT_ADMIN_ROLE (upgrade
 *      authority on all three proxies), but currently has NO code on-chain. Confirm the TimeLock
 *      contract is deployed at this address BEFORE running — otherwise admin lands on an empty address.
 */
contract TransferRoleSlisXAUEMainnet is Script {
  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  // Production custody
  address public constant ADMIN = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253; // -> DEFAULT_ADMIN_ROLE (24h TimeLock; confirm deployed first)
  address public constant MANAGER_MULTISIG = 0x8d388136d578dCD791D081c6042284CED6d9B0c6; // -> MANAGER (Safe)

  // Deployed proxies (Ethereum mainnet)
  address public constant SLISXAUE = 0x97b0A9c6A4d9fD51Bf8beBf04015F74C2e36A624;
  address public constant STAKING = 0x86c92fF74fa55b08b4fA0d59E41e26b14ed1150b;
  address public constant ADAPTER = 0x7509661232741c6912E278193404b912FC342F30;

  function run() public {
    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(pk);

    console.log("Deployer (renouncing):", deployer);
    console.log("DEFAULT_ADMIN ->", ADMIN);
    console.log("MANAGER ->", MANAGER_MULTISIG);

    vm.startBroadcast(pk);

    // SlisXAUE: only DEFAULT_ADMIN (MINTER stays = XAUTStaking).
    IAccessControl(SLISXAUE).grantRole(DEFAULT_ADMIN_ROLE, ADMIN);
    IAccessControl(SLISXAUE).renounceRole(DEFAULT_ADMIN_ROLE, deployer);

    // XAUTStaking: DEFAULT_ADMIN -> ADMIN, MANAGER -> multisig (PAUSER already final).
    IAccessControl(STAKING).grantRole(MANAGER, MANAGER_MULTISIG);
    IAccessControl(STAKING).grantRole(DEFAULT_ADMIN_ROLE, ADMIN);
    IAccessControl(STAKING).renounceRole(MANAGER, deployer);
    IAccessControl(STAKING).renounceRole(DEFAULT_ADMIN_ROLE, deployer);

    // XAUEAdapter: DEFAULT_ADMIN -> ADMIN, MANAGER -> multisig (BOT already final).
    IAccessControl(ADAPTER).grantRole(MANAGER, MANAGER_MULTISIG);
    IAccessControl(ADAPTER).grantRole(DEFAULT_ADMIN_ROLE, ADMIN);
    IAccessControl(ADAPTER).renounceRole(MANAGER, deployer);
    IAccessControl(ADAPTER).renounceRole(DEFAULT_ADMIN_ROLE, deployer);

    vm.stopBroadcast();

    console.log(
      "Done. Verify: each proxy DEFAULT_ADMIN member==ADMIN & count==1; MANAGER==multisig; deployer holds nothing."
    );
  }
}
