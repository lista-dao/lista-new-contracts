// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LisAsterBase } from "./LisAsterBase.t.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AsterRewards } from "../../src/lisaster/AsterRewards.sol";

contract AsterRewardsTest is LisAsterBase {
  /* ---------------- notifyRewards ---------------- */

  function test_notifyRewards_holdsAster() public {
    _managerNotify(5 ether);

    // ASTER lands in Rewards. No Vault round-trip; no lisAster minted.
    assertEq(asterToken.balanceOf(lisAsterManager), 0);
    assertEq(asterToken.balanceOf(address(rewards)), 5 ether);
    assertEq(asterToken.balanceOf(address(astherusVault)), 0);
    assertEq(rewards.pendingAster(), 5 ether);
    assertEq(lisAster.totalSupply(), 0);
  }

  function test_notifyRewards_onlyBot() public {
    asterToken.mint(lisAsterManager, 1 ether);
    vm.prank(lisAsterManager);
    asterToken.approve(address(rewards), 1 ether);

    bytes32 botRole = rewards.BOT();
    // MANAGER can no longer notify.
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, botRole));
    vm.prank(manager);
    rewards.notifyRewards(1 ether);
    // Random caller cannot notify.
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, botRole));
    vm.prank(other);
    rewards.notifyRewards(1 ether);

    // BOT can.
    vm.prank(bot);
    rewards.notifyRewards(1 ether);
    assertEq(asterToken.balanceOf(address(rewards)), 1 ether);
  }

  function test_notifyRewards_revertsZero() public {
    vm.prank(bot);
    vm.expectRevert(bytes("zero amount"));
    rewards.notifyRewards(0);
  }

  function test_notifyRewards_revertsWhenManagerUnset() public {
    // Fresh Rewards proxy with no setLisAsterManager call.
    AsterRewards fresh = AsterRewards(address(new ERC1967Proxy(address(new AsterRewards()), "")));
    fresh.initialize(admin, pauser, manager, bot, address(asterToken));

    vm.prank(bot);
    vm.expectRevert(bytes("lisAsterManager not set"));
    fresh.notifyRewards(1 ether);
  }

  function test_notifyRewards_revertsWithoutAllowance() public {
    // lisAsterManager funded but did NOT approve Rewards.
    asterToken.mint(lisAsterManager, 1 ether);
    vm.prank(bot);
    vm.expectRevert(); // ERC20InsufficientAllowance
    rewards.notifyRewards(1 ether);
  }

  /* ---------------- distributeRewards ---------------- */

  function test_distributeRewards_callsDistributorNotify() public {
    _managerNotify(10 ether);

    vm.prank(bot);
    rewards.distributeRewards(3 ether);

    // ASTER flows into distributor.
    assertEq(asterToken.balanceOf(address(rewards)), 7 ether);
    assertEq(asterToken.balanceOf(address(distributor)), 3 ether);
    assertEq(distributor.totalNotified(), 3 ether);
  }

  function test_distributeRewards_partialBatching() public {
    _managerNotify(10 ether);

    _botDistribute(2 ether);
    _botDistribute(5 ether);

    assertEq(asterToken.balanceOf(address(rewards)), 3 ether);
    assertEq(asterToken.balanceOf(address(distributor)), 7 ether);
    assertEq(distributor.totalNotified(), 7 ether);
  }

  function test_distributeRewards_onlyBot() public {
    _managerNotify(1 ether);
    bytes32 role = rewards.BOT();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    rewards.distributeRewards(1 ether);
  }

  function test_distributeRewards_revertsExceedsBalance() public {
    _managerNotify(1 ether);
    vm.prank(bot);
    vm.expectRevert(bytes("exceeds balance"));
    rewards.distributeRewards(2 ether);
  }

  /* ---------------- one-shot setDistributor ---------------- */

  function test_setDistributor_revertsIfAlreadySet() public {
    vm.prank(manager);
    vm.expectRevert(bytes("distributor already set"));
    rewards.setDistributor(address(0xDEAD));
  }

  function test_setDistributor_onlyManager() public {
    bytes32 role = rewards.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
    vm.prank(admin);
    rewards.setDistributor(address(0xDEAD));
  }

  /* ---------------- setLisAsterManager ---------------- */

  function test_setLisAsterManager_byManager() public {
    vm.prank(manager);
    rewards.setLisAsterManager(other);
    assertEq(rewards.lisAsterManager(), other);
  }

  function test_setLisAsterManager_revertsZero() public {
    vm.prank(manager);
    vm.expectRevert(bytes("lisAsterManager is zero"));
    rewards.setLisAsterManager(address(0));
  }

  function test_setLisAsterManager_onlyManager() public {
    bytes32 role = rewards.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
    vm.prank(admin);
    rewards.setLisAsterManager(other);
  }

  /* ---------------- fee setters ---------------- */

  function test_setFeeReceiver_byManager() public {
    vm.prank(manager);
    rewards.setFeeReceiver(other);
    assertEq(rewards.feeReceiver(), other);
  }

  function test_setFeeReceiver_revertsZero() public {
    vm.prank(manager);
    vm.expectRevert(bytes("feeReceiver is zero"));
    rewards.setFeeReceiver(address(0));
  }

  function test_setFeeReceiver_onlyManager() public {
    bytes32 role = rewards.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
    vm.prank(admin);
    rewards.setFeeReceiver(other);
  }

  function test_setFeeRate_byManager() public {
    vm.prank(manager);
    rewards.setFeeRate(1e17); // 10%
    assertEq(rewards.feeRate(), 1e17);
  }

  function test_setFeeRate_capEnforced() public {
    uint256 cap = rewards.MAX_FEE_RATE();
    vm.prank(manager);
    vm.expectRevert(bytes("feeRate too high"));
    rewards.setFeeRate(cap + 1);
  }

  function test_setFeeRate_atCap() public {
    uint256 cap = rewards.MAX_FEE_RATE();
    vm.prank(manager);
    rewards.setFeeRate(cap);
    assertEq(rewards.feeRate(), 3e17);
  }

  function test_setFeeRate_onlyManager() public {
    bytes32 role = rewards.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
    vm.prank(admin);
    rewards.setFeeRate(1e17);
  }

  /* ---------------- notifyRewards with fee ---------------- */

  function test_notifyRewards_zeroFeeRate_noFeeTaken() public {
    // Default state: feeRate = 0, feeReceiver = 0. No fee path.
    address recipient = makeAddr("feeRecipient");
    _managerNotify(10 ether);

    assertEq(asterToken.balanceOf(recipient), 0, "no fee taken");
    assertEq(asterToken.balanceOf(address(rewards)), 10 ether, "all retained");
  }

  function test_notifyRewards_withFee_splitsCorrectly() public {
    address recipient = makeAddr("feeRecipient");
    vm.startPrank(manager);
    rewards.setFeeReceiver(recipient);
    rewards.setFeeRate(1e17); // 10%
    vm.stopPrank();

    _managerNotify(10 ether);

    // 10% fee = 1 ASTER to recipient, 9 ASTER stays in Rewards as ASTER.
    assertEq(asterToken.balanceOf(recipient), 1 ether, "fee transferred");
    assertEq(asterToken.balanceOf(address(rewards)), 9 ether, "net retained");
  }

  function test_notifyRewards_feeRateSetButNoReceiver_skipsFee() public {
    vm.prank(manager);
    rewards.setFeeRate(1e17); // 10%

    _managerNotify(10 ether);

    // No fee transferred anywhere; full 10 ether retained.
    assertEq(asterToken.balanceOf(address(rewards)), 10 ether);
  }

  function test_notifyRewards_receiverSetButZeroRate_skipsFee() public {
    address recipient = makeAddr("feeRecipient");
    vm.prank(manager);
    rewards.setFeeReceiver(recipient);

    _managerNotify(10 ether);

    assertEq(asterToken.balanceOf(recipient), 0);
    assertEq(asterToken.balanceOf(address(rewards)), 10 ether);
  }

  function test_notifyRewards_atCapFee() public {
    address recipient = makeAddr("feeRecipient");
    vm.startPrank(manager);
    rewards.setFeeReceiver(recipient);
    rewards.setFeeRate(rewards.MAX_FEE_RATE()); // 30%
    vm.stopPrank();

    _managerNotify(10 ether);

    assertEq(asterToken.balanceOf(recipient), 3 ether);
    assertEq(asterToken.balanceOf(address(rewards)), 7 ether);
  }

  /* ---------------- emergencyWithdraw ---------------- */

  function test_emergencyWithdraw_byManager() public {
    _managerNotify(5 ether);
    uint256 balBefore = asterToken.balanceOf(address(rewards));

    vm.prank(manager);
    rewards.emergencyWithdraw(address(asterToken), 2 ether);

    // Funds go to the MANAGER caller.
    assertEq(asterToken.balanceOf(manager), 2 ether);
    assertEq(asterToken.balanceOf(address(rewards)), balBefore - 2 ether);
  }

  function test_emergencyWithdraw_onlyManager() public {
    _managerNotify(1 ether);
    // BOT explicitly cannot evacuate funds.
    bytes32 role = rewards.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, role));
    vm.prank(bot);
    rewards.emergencyWithdraw(address(asterToken), 1 ether);
  }

  function test_emergencyWithdraw_zeroChecks() public {
    vm.startPrank(manager);
    vm.expectRevert(bytes("zero token"));
    rewards.emergencyWithdraw(address(0), 1 ether);
    vm.expectRevert(bytes("zero amount"));
    rewards.emergencyWithdraw(address(asterToken), 0);
    vm.stopPrank();
  }

  /* ---------------- pause / unpause ---------------- */

  function test_pause_byPauser() public {
    vm.prank(pauser);
    rewards.pause();
    assertTrue(rewards.paused());
  }

  function test_pause_revertsForOther() public {
    bytes32 role = rewards.PAUSER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    rewards.pause();
  }

  function test_unpause_byManager() public {
    vm.prank(pauser);
    rewards.pause();
    vm.prank(manager);
    rewards.unpause();
    assertFalse(rewards.paused());
  }

  function test_unpause_revertsForPauser() public {
    vm.prank(pauser);
    rewards.pause();
    bytes32 role = rewards.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, role));
    vm.prank(pauser);
    rewards.unpause();
  }
}
