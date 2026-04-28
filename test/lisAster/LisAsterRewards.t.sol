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
}
