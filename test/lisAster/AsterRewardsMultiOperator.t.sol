// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { LisAsterBase } from "./LisAsterBase.t.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AsterRewards } from "../../src/lisaster/AsterRewards.sol";
import { IAsterRewards } from "../../src/lisaster/interface/IAsterRewards.sol";

/// @dev Covers the multi-operator upgrade: operator whitelist, `notifyRewards(operators, amounts)`,
///      and the `initializeV2` migration path.
contract AsterRewardsMultiOperatorTest is LisAsterBase {
  address opA = makeAddr("opA");
  address opB = makeAddr("opB");

  /// @dev Fund a source and approve Rewards, without triggering a notify.
  function _fundApprove(address src, uint256 amount) internal {
    asterToken.mint(src, amount);
    vm.prank(src);
    asterToken.approve(address(rewards), amount);
  }

  /* ---------------- addOperator / removeOperator ---------------- */

  function test_addOperator_byManager() public {
    vm.expectEmit(true, false, false, false, address(rewards));
    emit IAsterRewards.OperatorAdded(opA);
    vm.prank(manager);
    rewards.addOperator(opA);
    assertTrue(rewards.isOperator(opA));
  }

  function test_addOperator_revertsZero() public {
    vm.prank(manager);
    vm.expectRevert(bytes("operator is zero"));
    rewards.addOperator(address(0));
  }

  function test_addOperator_revertsDuplicate() public {
    vm.startPrank(manager);
    rewards.addOperator(opA);
    vm.expectRevert(bytes("already operator"));
    rewards.addOperator(opA);
    vm.stopPrank();
  }

  function test_addOperator_onlyManager() public {
    bytes32 role = rewards.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    rewards.addOperator(opA);
  }

  function test_removeOperator_byManager() public {
    vm.startPrank(manager);
    rewards.addOperator(opA);
    vm.expectEmit(true, false, false, false, address(rewards));
    emit IAsterRewards.OperatorRemoved(opA);
    rewards.removeOperator(opA);
    vm.stopPrank();
    assertFalse(rewards.isOperator(opA));
  }

  function test_removeOperator_revertsNotOperator() public {
    vm.prank(manager);
    vm.expectRevert(bytes("not operator"));
    rewards.removeOperator(opA);
  }

  function test_removeOperator_onlyManager() public {
    vm.prank(manager);
    rewards.addOperator(opA);
    bytes32 role = rewards.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    rewards.removeOperator(opA);
  }

  /* ---------------- setOperator mirrors into whitelist ---------------- */

  function test_setOperator_addsToWhitelist() public {
    // Base setUp already setOperator(operator); the default must be whitelisted.
    assertTrue(rewards.isOperator(operator));

    vm.prank(manager);
    rewards.setOperator(opA);
    assertEq(rewards.operator(), opA);
    assertTrue(rewards.isOperator(opA));
    // Previous default stays whitelisted until explicitly removed.
    assertTrue(rewards.isOperator(operator));
  }

  /* ---------------- notifyRewards(operators, amounts) ---------------- */

  function test_notifyRewards_multipleOperators() public {
    vm.startPrank(manager);
    rewards.addOperator(opA);
    rewards.addOperator(opB);
    vm.stopPrank();
    _fundApprove(operator, 3 ether);
    _fundApprove(opA, 5 ether);
    _fundApprove(opB, 10 ether);

    // BOT names each source and how much to pull from it.
    vm.prank(bot);
    rewards.notifyRewards(_addrs(operator, opA, opB), _amts(3 ether, 5 ether, 1 ether));

    assertEq(asterToken.balanceOf(operator), 0);
    assertEq(asterToken.balanceOf(opA), 0);
    assertEq(asterToken.balanceOf(opB), 9 ether, "only the requested 1 pulled");
    assertEq(asterToken.balanceOf(address(rewards)), 9 ether, "total collected");
  }

  function test_notifyRewards_sameOperatorTwice() public {
    _fundApprove(operator, 5 ether);

    vm.prank(bot);
    rewards.notifyRewards(_addrs(operator, operator), _amts(2 ether, 3 ether));

    assertEq(asterToken.balanceOf(operator), 0);
    assertEq(asterToken.balanceOf(address(rewards)), 5 ether);
  }

  function test_notifyRewards_revertsEmpty() public {
    vm.prank(bot);
    vm.expectRevert(bytes("no operators"));
    rewards.notifyRewards(new address[](0), new uint256[](0));
  }

  function test_notifyRewards_revertsLengthMismatch() public {
    vm.prank(bot);
    vm.expectRevert(bytes("length mismatch"));
    rewards.notifyRewards(_addrs(operator), _amts(1 ether, 1 ether));
  }

  function test_notifyRewards_revertsNonWhitelisted() public {
    _fundApprove(opA, 1 ether);
    vm.prank(bot);
    vm.expectRevert(bytes("not operator"));
    rewards.notifyRewards(_addrs(opA), _amts(1 ether));
  }

  function test_notifyRewards_revertsRemovedOperator() public {
    vm.startPrank(manager);
    rewards.addOperator(opA);
    rewards.removeOperator(opA);
    vm.stopPrank();
    _fundApprove(opA, 1 ether);

    vm.prank(bot);
    vm.expectRevert(bytes("not operator"));
    rewards.notifyRewards(_addrs(opA), _amts(1 ether));
  }

  function test_notifyRewards_revertsZeroEntry_rollsBack() public {
    vm.prank(manager);
    rewards.addOperator(opA);
    _fundApprove(operator, 1 ether);
    _fundApprove(opA, 1 ether);

    // A zero entry after a valid pull reverts the whole call.
    vm.prank(bot);
    vm.expectRevert(bytes("zero amount"));
    rewards.notifyRewards(_addrs(operator, opA), _amts(1 ether, 0));

    assertEq(asterToken.balanceOf(operator), 1 ether, "rolled back");
    assertEq(asterToken.balanceOf(address(rewards)), 0);
  }

  function test_notifyRewards_revertsInsufficientAllowance_rollsBack() public {
    vm.prank(manager);
    rewards.addOperator(opA);
    _fundApprove(operator, 2 ether);
    _fundApprove(opA, 1 ether);

    // opA approved only 1 but 3 is requested: the whole call reverts, including operator's pull.
    vm.prank(bot);
    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(rewards), 1 ether, 3 ether)
    );
    rewards.notifyRewards(_addrs(operator, opA), _amts(2 ether, 3 ether));

    assertEq(asterToken.balanceOf(operator), 2 ether, "rolled back");
    assertEq(asterToken.balanceOf(opA), 1 ether, "rolled back");
    assertEq(asterToken.balanceOf(address(rewards)), 0);
  }

  /* ---------------- fee on the total ---------------- */

  function test_notifyRewards_feeOnTotalOnce() public {
    address recipient = makeAddr("feeRecipient");
    vm.startPrank(manager);
    rewards.setFeeReceiver(recipient);
    rewards.setFeeRate(1e17); // 10%
    rewards.addOperator(opA);
    rewards.addOperator(opB);
    vm.stopPrank();
    _fundApprove(operator, 10 ether);
    _fundApprove(opA, 10 ether);
    _fundApprove(opB, 10 ether);

    // One call pulls 30 in total; fee is computed once on the total (3), not per pull.
    vm.expectEmit(false, false, false, true, address(rewards));
    emit IAsterRewards.RewardsNotified(30 ether, 3 ether, 27 ether);
    vm.prank(bot);
    rewards.notifyRewards(_addrs(operator, opA, opB), _amts(10 ether, 10 ether, 10 ether));

    assertEq(asterToken.balanceOf(recipient), 3 ether, "fee once on total");
    assertEq(asterToken.balanceOf(address(rewards)), 27 ether, "net retained");
  }

  function test_notifyRewards_feeRoundsOnTotal() public {
    // 10% of each 5-wei pull floors to 0, but 10% of the 10-wei total is 1: proves the fee is
    // computed once on the total, not per operator pull.
    address recipient = makeAddr("feeRecipient");
    vm.startPrank(manager);
    rewards.setFeeReceiver(recipient);
    rewards.setFeeRate(1e17); // 10%
    rewards.addOperator(opA);
    vm.stopPrank();
    _fundApprove(operator, 5);
    _fundApprove(opA, 5);

    vm.expectEmit(false, false, false, true, address(rewards));
    emit IAsterRewards.RewardsNotified(10, 1, 9);
    vm.prank(bot);
    rewards.notifyRewards(_addrs(operator, opA), _amts(5, 5));

    assertEq(asterToken.balanceOf(recipient), 1);
    assertEq(asterToken.balanceOf(address(rewards)), 9);
  }

  function test_notifyRewards_emitsPerCallValues() public {
    address recipient = makeAddr("feeRecipient");
    vm.startPrank(manager);
    rewards.setFeeReceiver(recipient);
    rewards.setFeeRate(1e17); // 10%
    rewards.addOperator(opA);
    vm.stopPrank();
    _fundApprove(opA, 8 ether);

    // A first round, so cumulative totals would differ from this call's values.
    vm.prank(bot);
    rewards.notifyRewards(_addrs(opA), _amts(5 ether));

    // Original semantics: event carries this call's (amount, fee, net), not historical totals.
    vm.expectEmit(false, false, false, true, address(rewards));
    emit IAsterRewards.RewardsNotified(3 ether, 0.3 ether, 2.7 ether);
    vm.prank(bot);
    rewards.notifyRewards(_addrs(opA), _amts(3 ether));
  }

  /* ---------------- views ---------------- */

  function test_views_operatorSetEnumeration() public {
    // Base setUp whitelisted `operator`.
    assertEq(rewards.operatorCount(), 1);

    vm.startPrank(manager);
    rewards.addOperator(opA);
    rewards.addOperator(opB);
    vm.stopPrank();

    assertEq(rewards.operatorCount(), 3);
    address[] memory ops = rewards.getOperators();
    assertEq(ops.length, 3);
  }

  /* ---------------- initializeV2 migration ---------------- */

  /// @dev A v1-shaped proxy: initialized once, optionally with a legacy `operator` written to slot 4
  ///      and no whitelist entry (the whitelist did not exist pre-upgrade).
  function _freshV1(address legacy) internal returns (AsterRewards fresh) {
    fresh = AsterRewards(address(new ERC1967Proxy(address(new AsterRewards()), "")));
    fresh.initialize(admin, pauser, manager, bot, address(asterToken));
    if (legacy != address(0)) {
      vm.store(address(fresh), bytes32(uint256(4)), bytes32(uint256(uint160(legacy))));
    }
  }

  function test_initializeV2_migratesLegacyOperator() public {
    address legacy = makeAddr("legacyOperator");
    AsterRewards fresh = _freshV1(legacy);
    assertEq(fresh.operator(), legacy);
    assertFalse(fresh.isOperator(legacy), "not yet migrated");

    // Seeds both the pre-existing `operator` and the passed `newOperator`, emitting for each.
    vm.expectEmit(true, false, false, false, address(fresh));
    emit IAsterRewards.OperatorAdded(legacy);
    vm.expectEmit(true, false, false, false, address(fresh));
    emit IAsterRewards.OperatorAdded(opA);
    vm.prank(admin);
    fresh.initializeV2(opA);

    assertTrue(fresh.isOperator(legacy), "legacy operator migrated into whitelist");
    assertTrue(fresh.isOperator(opA), "newOperator seeded into whitelist");
    assertEq(fresh.operatorCount(), 2);

    // notifyRewards can now pull from the migrated legacy operator.
    asterToken.mint(legacy, 2 ether);
    vm.prank(legacy);
    asterToken.approve(address(fresh), 2 ether);
    vm.prank(bot);
    fresh.notifyRewards(_addrs(legacy), _amts(2 ether));
    assertEq(asterToken.balanceOf(address(fresh)), 2 ether);
  }

  function test_initializeV2_viaUpgradeToAndCall() public {
    // The production path: DEFAULT_ADMIN upgrades and calls initializeV2 atomically. The role check
    // inside initializeV2 sees the upgrade caller as msg.sender.
    address legacy = makeAddr("legacyOperator");
    AsterRewards fresh = _freshV1(legacy);
    address newImpl = address(new AsterRewards());

    vm.expectEmit(true, false, false, false, address(fresh));
    emit IAsterRewards.OperatorAdded(legacy);
    vm.expectEmit(true, false, false, false, address(fresh));
    emit IAsterRewards.OperatorAdded(opA);
    vm.prank(admin);
    fresh.upgradeToAndCall(newImpl, abi.encodeCall(AsterRewards.initializeV2, (opA)));

    assertTrue(fresh.isOperator(legacy));
    assertTrue(fresh.isOperator(opA));
    assertEq(fresh.operatorCount(), 2);
    assertEq(fresh.operator(), legacy, "legacy slot untouched");
  }

  function test_initializeV2_onlyAdmin() public {
    AsterRewards fresh = _freshV1(makeAddr("legacyOperator"));
    bytes32 role = fresh.DEFAULT_ADMIN_ROLE();

    // A non-admin cannot run the migration, so it cannot consume the reinitializer either...
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    fresh.initializeV2(other);
    assertEq(fresh.operatorCount(), 0);

    // ...and the admin can still run it afterwards.
    vm.prank(admin);
    fresh.initializeV2(opA);
    assertEq(fresh.operatorCount(), 2);
  }

  function test_initializeV2_seedsNewOperatorWhenNoLegacy() public {
    // No legacy operator set: only the passed newOperator is whitelisted.
    AsterRewards fresh = _freshV1(address(0));

    vm.prank(admin);
    fresh.initializeV2(opA);

    assertFalse(fresh.isOperator(address(0)), "zero not whitelisted");
    assertTrue(fresh.isOperator(opA), "newOperator whitelisted");
    assertEq(fresh.operatorCount(), 1);
  }

  function test_initializeV2_sameAddressAsLegacy() public {
    // Passing the legacy operator again is a no-op for the second add (no revert, no duplicate).
    address legacy = makeAddr("legacyOperator");
    AsterRewards fresh = _freshV1(legacy);

    vm.recordLogs();
    vm.prank(admin);
    fresh.initializeV2(legacy);

    assertEq(_countLogs(address(fresh), IAsterRewards.OperatorAdded.selector), 1, "single OperatorAdded");
    assertTrue(fresh.isOperator(legacy));
    assertEq(fresh.operatorCount(), 1);
  }

  function test_initializeV2_cannotRunTwice() public {
    AsterRewards fresh = _freshV1(address(0));
    vm.startPrank(admin);
    fresh.initializeV2(opA);
    vm.expectRevert(); // InvalidInitialization: reinitializer(2) already consumed
    fresh.initializeV2(opB);
    vm.stopPrank();
  }

  /* ---------------- OperatorAdded coverage for setOperator ---------------- */

  function test_setOperator_emitsOperatorAddedOnlyWhenNew() public {
    bytes32 addedSig = IAsterRewards.OperatorAdded.selector;

    // New address: OperatorAdded is emitted.
    vm.recordLogs();
    vm.prank(manager);
    rewards.setOperator(opA);
    assertEq(_countLogs(address(rewards), addedSig), 1, "emitted for a new operator");

    // Already whitelisted: SetOperator only, no duplicate OperatorAdded.
    vm.recordLogs();
    vm.prank(manager);
    rewards.setOperator(operator);
    assertEq(_countLogs(address(rewards), addedSig), 0, "not emitted when already whitelisted");
  }

  function _countLogs(address emitter, bytes32 sig) internal returns (uint256 n) {
    Vm.Log[] memory logs = vm.getRecordedLogs();
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == sig) n++;
    }
  }
}
