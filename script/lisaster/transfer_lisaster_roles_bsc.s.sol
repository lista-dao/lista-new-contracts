// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title TransferLisAsterRolesBsc
/// @notice One-shot BSC mainnet role-rotation for the 5 lisAster proxies. Run AFTER
///         `deploy_lisaster_bsc.s.sol` and AFTER on-chain verification.
///
///         The deploy script already wires PAUSER / BOT / lisAsterManager / feeReceiver to
///         their final holders, so this script only needs to rotate the two roles that stayed
///         on the deployer for safety:
///             1. MANAGER on Vault / Staking / Rewards / Distributor  -> MANAGER multisig
///             2. DEFAULT_ADMIN on all 5 proxies                       -> ADMIN multisig
///         The Rewards MANAGER is the same multisig as the ops MANAGER per the deploy script.
///
///         For every proxy:
///           1. grantRole(target_role, final_holder)
///           2. revokeRole(target_role, deployer)
///         DEFAULT_ADMIN is rotated LAST on each contract so we never lose the ability to grant
///         other roles mid-flight.
///
///         The LisAster proxy only has DEFAULT_ADMIN + MINTER; MINTER is held by AsterVault and
///         is NOT touched here.
///
///         Run: forge script script/lisaster/transfer_lisaster_roles_bsc.s.sol:TransferLisAsterRolesBsc \
///                 --rpc-url bsc --broadcast -vvvv
contract TransferLisAsterRolesBsc is Script {
  /* ----- Proxies (BSC mainnet) ----- */
  address constant LIS_ASTER = 0xa17A497D20cC143508FE3b63578b13ba6b9c9f06;
  address constant ASTER_VAULT = 0xb3Df1b695D720dDc5906005DD5448DB160687C42;
  address constant LIS_ASTER_STAKING = 0x3D786C991452Cb7634D02b351374CB0aCC69fD71;
  address constant LIS_ASTER_REWARDS = 0x2bB41616323994b4ADa381EA40Cb2d135f7b2462;
  address constant LIS_ASTER_DISTRIBUTOR = 0x9e80FeC60bd4A9FeD7aF740Ba8d0104e05AC227d;

  /* ----- Final role holders ----- */
  /// @dev DEFAULT_ADMIN across all 5 proxies. Lista governance multisig.
  address constant ADMIN = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  /// @dev MANAGER across Vault (setLisAsterManager), Staking (emergencyWithdraw),
  ///      Rewards (notifyRewards / setDistributor / fee setters) and Distributor
  ///      (revokePendingMerkleRoot + emergencyWithdraw). Single Lista ops multisig.
  address constant MANAGER = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  /* Role IDs (bytes32). DEFAULT_ADMIN_ROLE is the zero bytes32 from OpenZeppelin AccessControl. */
  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 constant MANAGER_ROLE = keccak256("MANAGER");

  function run() public {
    require(block.chainid == 56, "expect BSC mainnet (chainId 56)");

    _requireSet(LIS_ASTER, "LIS_ASTER");
    _requireSet(ASTER_VAULT, "ASTER_VAULT");
    _requireSet(LIS_ASTER_STAKING, "LIS_ASTER_STAKING");
    _requireSet(LIS_ASTER_REWARDS, "LIS_ASTER_REWARDS");
    _requireSet(LIS_ASTER_DISTRIBUTOR, "LIS_ASTER_DISTRIBUTOR");
    _requireSet(ADMIN, "ADMIN");
    _requireSet(MANAGER, "MANAGER");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPk);

    console.log("Chain ID:        ", block.chainid);
    console.log("Deployer:        ", deployer);
    console.log("ADMIN target:    ", ADMIN);
    console.log("MANAGER target:  ", MANAGER);

    /* Pre-flight: deployer must currently hold DEFAULT_ADMIN_ROLE on every proxy. */
    _preflight(LIS_ASTER, deployer);
    _preflight(ASTER_VAULT, deployer);
    _preflight(LIS_ASTER_STAKING, deployer);
    _preflight(LIS_ASTER_REWARDS, deployer);
    _preflight(LIS_ASTER_DISTRIBUTOR, deployer);

    vm.startBroadcast(deployerPk);

    /* ----- LisAster: only DEFAULT_ADMIN. MINTER stays on AsterVault. ----- */
    _rotateAdmin(LIS_ASTER, deployer, ADMIN);

    /* ----- AsterVault: DEFAULT_ADMIN + MANAGER (PAUSER already wired at deploy) ----- */
    _rotateRole(ASTER_VAULT, MANAGER_ROLE, deployer, MANAGER);
    _rotateAdmin(ASTER_VAULT, deployer, ADMIN);

    /* ----- LisAsterStaking: DEFAULT_ADMIN + MANAGER ----- */
    _rotateRole(LIS_ASTER_STAKING, MANAGER_ROLE, deployer, MANAGER);
    _rotateAdmin(LIS_ASTER_STAKING, deployer, ADMIN);

    /* ----- AsterRewards: DEFAULT_ADMIN + MANAGER (BOT already wired at deploy) ----- */
    _rotateRole(LIS_ASTER_REWARDS, MANAGER_ROLE, deployer, MANAGER);
    _rotateAdmin(LIS_ASTER_REWARDS, deployer, ADMIN);

    /* ----- LisAsterDistributor: DEFAULT_ADMIN + MANAGER (BOT already wired at deploy) ----- */
    _rotateRole(LIS_ASTER_DISTRIBUTOR, MANAGER_ROLE, deployer, MANAGER);
    _rotateAdmin(LIS_ASTER_DISTRIBUTOR, deployer, ADMIN);

    vm.stopBroadcast();

    /* ----- Post-flight assertions ----- */
    _postflight(LIS_ASTER, deployer, ADMIN);

    _postflight(ASTER_VAULT, deployer, ADMIN);
    _assertRole(ASTER_VAULT, MANAGER_ROLE, MANAGER, true);
    _assertRole(ASTER_VAULT, MANAGER_ROLE, deployer, false);

    _postflight(LIS_ASTER_STAKING, deployer, ADMIN);
    _assertRole(LIS_ASTER_STAKING, MANAGER_ROLE, MANAGER, true);
    _assertRole(LIS_ASTER_STAKING, MANAGER_ROLE, deployer, false);

    _postflight(LIS_ASTER_REWARDS, deployer, ADMIN);
    _assertRole(LIS_ASTER_REWARDS, MANAGER_ROLE, MANAGER, true);
    _assertRole(LIS_ASTER_REWARDS, MANAGER_ROLE, deployer, false);

    _postflight(LIS_ASTER_DISTRIBUTOR, deployer, ADMIN);
    _assertRole(LIS_ASTER_DISTRIBUTOR, MANAGER_ROLE, MANAGER, true);
    _assertRole(LIS_ASTER_DISTRIBUTOR, MANAGER_ROLE, deployer, false);

    console.log("---- Role rotation complete on all 5 proxies ----");
  }

  /* ----- Helpers ----- */

  /// @dev Rotate a non-admin role: grant to `to`, revoke from `from`.
  function _rotateRole(address ca, bytes32 role, address from, address to) private {
    if (!IAccessControl(ca).hasRole(role, to)) {
      IAccessControl(ca).grantRole(role, to);
    }
    if (IAccessControl(ca).hasRole(role, from)) {
      IAccessControl(ca).revokeRole(role, from);
    }
  }

  /// @dev Rotate DEFAULT_ADMIN_ROLE last so we keep grant/revoke power until everything else is done.
  function _rotateAdmin(address ca, address from, address to) private {
    if (!IAccessControl(ca).hasRole(DEFAULT_ADMIN_ROLE, to)) {
      IAccessControl(ca).grantRole(DEFAULT_ADMIN_ROLE, to);
    }
    // Use revokeRole rather than renounceRole so the call signature stays uniform with the
    // rest of the script. `from == deployer == msg.sender`, and deployer still holds
    // DEFAULT_ADMIN_ROLE at this point, so the revoke is allowed.
    if (IAccessControl(ca).hasRole(DEFAULT_ADMIN_ROLE, from)) {
      IAccessControl(ca).revokeRole(DEFAULT_ADMIN_ROLE, from);
    }
  }

  function _preflight(address ca, address deployer) private view {
    require(IAccessControl(ca).hasRole(DEFAULT_ADMIN_ROLE, deployer), "deployer lacks DEFAULT_ADMIN");
  }

  function _postflight(address ca, address deployer, address newAdmin) private view {
    require(IAccessControl(ca).hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "new admin not set");
    require(!IAccessControl(ca).hasRole(DEFAULT_ADMIN_ROLE, deployer), "deployer admin not revoked");
  }

  function _assertRole(address ca, bytes32 role, address who, bool expected) private view {
    require(IAccessControl(ca).hasRole(role, who) == expected, "role assertion failed");
  }

  function _requireSet(address a, string memory name) private pure {
    require(a != address(0), string.concat("unset: ", name));
  }
}
