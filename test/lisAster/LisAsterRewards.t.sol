// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LisAsterBase } from "./LisAsterBase.t.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

contract LisAsterRewardsTest is LisAsterBase {
  /* ---------------- notifyRewards ---------------- */

  function test_notifyRewards_mint1to1() public {
    asterToken.mint(manager, 5 ether);
    vm.startPrank(manager);
    asterToken.approve(address(rewards), 5 ether);
    rewards.notifyRewards(5 ether);
    vm.stopPrank();

    // ASTER traverses manager -> rewards -> vault -> AstherusVault BSC contract.
    assertEq(asterToken.balanceOf(manager), 0);
    assertEq(asterToken.balanceOf(address(rewards)), 0);
    assertEq(asterToken.balanceOf(address(vault)), 0);
    assertEq(asterToken.balanceOf(address(astherusVault)), 5 ether);

    // Rewards now holds 5 lisAster.
    assertEq(lisAster.balanceOf(address(rewards)), 5 ether);
    assertEq(rewards.pendingLisAster(), 5 ether);
    // Total supply increased.
    assertEq(lisAster.totalSupply(), 5 ether);
  }

  function test_notifyRewards_onlyManager() public {
    asterToken.mint(other, 1 ether);
    vm.startPrank(other);
    asterToken.approve(address(rewards), 1 ether);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, rewards.MANAGER())
    );
    rewards.notifyRewards(1 ether);
    vm.stopPrank();
  }

  function test_notifyRewards_revertsZero() public {
    vm.prank(manager);
    vm.expectRevert(bytes("zero amount"));
    rewards.notifyRewards(0);
  }

  /* ---------------- distributeRewards ---------------- */

  function test_distributeRewards_callsDistributorNotify() public {
    _managerNotify(10 ether);

    vm.prank(bot);
    rewards.distributeRewards(3 ether);

    // lisAster flows into distributor.
    assertEq(lisAster.balanceOf(address(rewards)), 7 ether);
    assertEq(lisAster.balanceOf(address(distributor)), 3 ether);
    // distributor totalNotified bumped.
    assertEq(distributor.totalNotified(), 3 ether);
  }

  function test_distributeRewards_partialBatching() public {
    _managerNotify(10 ether);

    _botDistribute(2 ether);
    _botDistribute(5 ether);

    assertEq(lisAster.balanceOf(address(rewards)), 3 ether);
    assertEq(lisAster.balanceOf(address(distributor)), 7 ether);
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
    asterToken.mint(manager, 10 ether);
    vm.startPrank(manager);
    asterToken.approve(address(rewards), 10 ether);
    rewards.notifyRewards(10 ether);
    vm.stopPrank();

    assertEq(asterToken.balanceOf(recipient), 0, "no fee taken");
    assertEq(lisAster.balanceOf(address(rewards)), 10 ether, "all minted");
    assertEq(asterToken.balanceOf(address(astherusVault)), 10 ether, "all bridged");
  }

  function test_notifyRewards_withFee_splitsCorrectly() public {
    address recipient = makeAddr("feeRecipient");
    vm.startPrank(manager);
    rewards.setFeeReceiver(recipient);
    rewards.setFeeRate(1e17); // 10%
    vm.stopPrank();

    asterToken.mint(manager, 10 ether);
    vm.startPrank(manager);
    asterToken.approve(address(rewards), 10 ether);
    rewards.notifyRewards(10 ether);
    vm.stopPrank();

    // 10% fee = 1 ASTER to recipient, 9 ASTER bridged → 9 lisAster minted.
    assertEq(asterToken.balanceOf(recipient), 1 ether, "fee transferred");
    assertEq(asterToken.balanceOf(address(astherusVault)), 9 ether, "net bridged");
    assertEq(lisAster.balanceOf(address(rewards)), 9 ether, "net minted");
    assertEq(lisAster.totalSupply(), 9 ether);
  }

  function test_notifyRewards_feeRateSetButNoReceiver_skipsFee() public {
    // feeRate set but feeReceiver still 0 -> outer guard skips the fee path entirely.
    vm.prank(manager);
    rewards.setFeeRate(1e17); // 10%

    asterToken.mint(manager, 10 ether);
    vm.startPrank(manager);
    asterToken.approve(address(rewards), 10 ether);
    rewards.notifyRewards(10 ether);
    vm.stopPrank();

    // No fee transferred anywhere; full 10 ether bridged + minted.
    assertEq(asterToken.balanceOf(address(astherusVault)), 10 ether);
    assertEq(lisAster.balanceOf(address(rewards)), 10 ether);
  }

  function test_notifyRewards_receiverSetButZeroRate_skipsFee() public {
    // Mirror case: feeReceiver set but feeRate=0 -> still no fee.
    address recipient = makeAddr("feeRecipient");
    vm.prank(manager);
    rewards.setFeeReceiver(recipient);

    asterToken.mint(manager, 10 ether);
    vm.startPrank(manager);
    asterToken.approve(address(rewards), 10 ether);
    rewards.notifyRewards(10 ether);
    vm.stopPrank();

    assertEq(asterToken.balanceOf(recipient), 0);
    assertEq(lisAster.balanceOf(address(rewards)), 10 ether);
  }

  function test_notifyRewards_atCapFee() public {
    address recipient = makeAddr("feeRecipient");
    vm.startPrank(manager);
    rewards.setFeeReceiver(recipient);
    rewards.setFeeRate(rewards.MAX_FEE_RATE()); // 30%
    vm.stopPrank();

    asterToken.mint(manager, 10 ether);
    vm.startPrank(manager);
    asterToken.approve(address(rewards), 10 ether);
    rewards.notifyRewards(10 ether);
    vm.stopPrank();

    assertEq(asterToken.balanceOf(recipient), 3 ether);
    assertEq(lisAster.balanceOf(address(rewards)), 7 ether);
  }
}
