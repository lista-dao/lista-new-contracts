// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LisAsterBase } from "./LisAsterBase.t.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract LisAsterStakingTest is LisAsterBase {
  function _stakeAs(address u, uint256 amount) internal {
    _giveAster(u, amount);
    _userDeposit(u, amount, u);
    vm.startPrank(u);
    lisAster.approve(address(staking), amount);
    staking.stake(amount);
    vm.stopPrank();
  }

  function test_initialState() public view {
    assertEq(staking.lisAster(), address(lisAster));
    assertEq(staking.totalSupply(), 0);
    assertEq(staking.balanceOf(user), 0);
  }

  /* ---------------- stake / unstake ---------------- */

  function test_stake() public {
    _stakeAs(user, 1 ether);
    assertEq(staking.balanceOf(user), 1 ether);
    assertEq(staking.totalSupply(), 1 ether);
    assertEq(lisAster.balanceOf(address(staking)), 1 ether);
  }

  function test_unstake() public {
    _stakeAs(user, 1 ether);
    vm.prank(user);
    staking.unstake(0.4 ether);
    assertEq(staking.balanceOf(user), 0.6 ether);
    assertEq(staking.totalSupply(), 0.6 ether);
    assertEq(lisAster.balanceOf(user), 0.4 ether);
  }

  function test_unstake_revertsWhenPaused() public {
    _stakeAs(user, 1 ether);
    vm.prank(pauser);
    staking.pause();
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vm.prank(user);
    staking.unstake(1 ether);
  }

  function test_stake_revertsWhenPaused() public {
    vm.prank(pauser);
    staking.pause();
    _giveAster(user, 1 ether);
    _userDeposit(user, 1 ether, user);
    vm.startPrank(user);
    lisAster.approve(address(staking), 1 ether);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    staking.stake(1 ether);
    vm.stopPrank();
  }

  /* ---------------- stakeFor ---------------- */

  function test_stakeFor_byAnyCaller() public {
    // stakeFor is permissionless: any caller can stake on behalf of `receiver`.
    _giveAster(user, 1 ether);
    _userDeposit(user, 1 ether, user);
    vm.startPrank(user);
    lisAster.approve(address(staking), 1 ether);
    staking.stakeFor(other, 1 ether);
    vm.stopPrank();

    assertEq(staking.balanceOf(user), 0);
    assertEq(staking.balanceOf(other), 1 ether);
    assertEq(staking.totalSupply(), 1 ether);
  }

  function test_stakeFor_byDistributor() public {
    // Mint lisAster directly to the distributor (simulates the claimAndStake flow).
    vm.prank(address(vault));
    lisAster.mint(address(distributor), 1 ether);

    vm.startPrank(address(distributor));
    lisAster.approve(address(staking), 1 ether);
    staking.stakeFor(user, 1 ether);
    vm.stopPrank();

    assertEq(staking.balanceOf(user), 1 ether);
    assertEq(staking.totalSupply(), 1 ether);
  }

  function test_stakeFor_revertsZeroReceiver() public {
    _giveAster(user, 1 ether);
    _userDeposit(user, 1 ether, user);
    vm.startPrank(user);
    lisAster.approve(address(staking), 1 ether);
    vm.expectRevert(bytes("receiver is zero"));
    staking.stakeFor(address(0), 1 ether);
    vm.stopPrank();
  }
}
