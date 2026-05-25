// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title TransferAsterRewardsV2RolesBsc
/// @notice Companion to `deploy_lisaster_rewards_v2_bsc.s.sol`. Run AFTER the v2 deploy and
///         after on-chain verification.
///
///         The v2 deploy already wires PAUSER / BOT to their final holders, so this script only
///         rotates the two roles that stayed on the deployer for safety:
///             1. MANAGER on AsterRewards + LisAsterDistributor  -> MANAGER multisig
///             2. DEFAULT_ADMIN on both proxies                   -> ADMIN multisig
///         The MANAGER multisig also gets Rewards.MANAGER (shared with ops MANAGER per the deploy script).
///
///         For every proxy:
///           1. grantRole(target_role, final_holder)
///           2. revokeRole(target_role, deployer)
///         DEFAULT_ADMIN is rotated LAST on each contract so we never lose the ability to grant
///         other roles mid-flight.
///
///         Run: forge script script/lisaster/transfer_lisaster_rewards_v2_roles_bsc.s.sol:TransferAsterRewardsV2RolesBsc \
///                 --rpc-url bsc --broadcast -vvvv
contract TransferAsterRewardsV2RolesBsc is Script {
  /* ----- v2 proxies (BSC mainnet) ----- */
  address constant ASTER_REWARDS_V2 = 0xe477D5d78675780aaF41344211781966dc619D38;
  address constant LIS_ASTER_DISTRIBUTOR_V2 = 0x4fE7fE032260df5002Ff9b1E4d3CaADcf4b43386;

  /* ----- Final role holders (same multisigs as the original transfer script) ----- */
  /// @dev DEFAULT_ADMIN across both v2 proxies. Lista governance multisig.
  address constant ADMIN = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  /// @dev MANAGER on AsterRewards (notifyRewards / setDistributor / fee setters) and
  ///      LisAsterDistributor (revokePendingMerkleRoot + emergencyWithdraw). Single Lista ops multisig.
  address constant MANAGER = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  /* Role IDs (bytes32). DEFAULT_ADMIN_ROLE is the zero bytes32 from OpenZeppelin AccessControl. */
  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 constant MANAGER_ROLE = keccak256("MANAGER");

  function run() public {
    require(block.chainid == 56, "expect BSC mainnet (chainId 56)");

    _requireSet(ASTER_REWARDS_V2, "ASTER_REWARDS_V2");
    _requireSet(LIS_ASTER_DISTRIBUTOR_V2, "LIS_ASTER_DISTRIBUTOR_V2");
    _requireSet(ADMIN, "ADMIN");
    _requireSet(MANAGER, "MANAGER");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPk);

    console.log("Chain ID:        ", block.chainid);
    console.log("Deployer:        ", deployer);
    console.log("ADMIN target:    ", ADMIN);
    console.log("MANAGER target:  ", MANAGER);

    /* Pre-flight: deployer must currently hold DEFAULT_ADMIN_ROLE on every v2 proxy. */
    _preflight(ASTER_REWARDS_V2, deployer);
    _preflight(LIS_ASTER_DISTRIBUTOR_V2, deployer);

    vm.startBroadcast(deployerPk);

    /* ----- AsterRewards: DEFAULT_ADMIN + MANAGER (PAUSER + BOT already wired at deploy) ----- */
    _rotateRole(ASTER_REWARDS_V2, MANAGER_ROLE, deployer, MANAGER);
    _rotateAdmin(ASTER_REWARDS_V2, deployer, ADMIN);

    /* ----- LisAsterDistributor: DEFAULT_ADMIN + MANAGER (PAUSER + BOT already wired at deploy) ----- */
    _rotateRole(LIS_ASTER_DISTRIBUTOR_V2, MANAGER_ROLE, deployer, MANAGER);
    _rotateAdmin(LIS_ASTER_DISTRIBUTOR_V2, deployer, ADMIN);

    vm.stopBroadcast();

    /* ----- Post-flight assertions ----- */
    _postflight(ASTER_REWARDS_V2, deployer, ADMIN);
    _assertRole(ASTER_REWARDS_V2, MANAGER_ROLE, MANAGER, true);
    _assertRole(ASTER_REWARDS_V2, MANAGER_ROLE, deployer, false);

    _postflight(LIS_ASTER_DISTRIBUTOR_V2, deployer, ADMIN);
    _assertRole(LIS_ASTER_DISTRIBUTOR_V2, MANAGER_ROLE, MANAGER, true);
    _assertRole(LIS_ASTER_DISTRIBUTOR_V2, MANAGER_ROLE, deployer, false);

    console.log("---- Role rotation complete on AsterRewards + LisAsterDistributor v2 ----");
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
