// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LisAsterBase } from "./LisAsterBase.t.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
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

  /* ---------------- emergencyWithdraw ---------------- */

  function test_emergencyWithdraw_lisAster_byManager() public {
    _stakeAs(user, 1 ether);

    // 0.3 lisAster surplus on top of staked principal.
    _giveAster(other, 0.3 ether);
    _userDeposit(other, 0.3 ether, other);
    vm.prank(other);
    lisAster.transfer(address(staking), 0.3 ether);

    vm.prank(manager);
    staking.emergencyWithdraw(address(lisAster), 0.3 ether);

    // Funds go to manager (msg.sender). Note: there is no on-chain protection of the staked
    // principal here -- this is an escape hatch and the runbook expects pause + reconciliation.
    assertEq(lisAster.balanceOf(manager), 0.3 ether);
    assertEq(lisAster.balanceOf(address(staking)), 1 ether);
  }

  function test_emergencyWithdraw_otherToken() public {
    // A foreign ERC20 lands on staking; manager can rescue any amount.
    asterToken.mint(address(staking), 3 ether);

    vm.prank(manager);
    staking.emergencyWithdraw(address(asterToken), 3 ether);

    assertEq(asterToken.balanceOf(manager), 3 ether);
  }

  function test_emergencyWithdraw_revertsZeroToken() public {
    vm.prank(manager);
    vm.expectRevert(bytes("zero token"));
    staking.emergencyWithdraw(address(0), 1);
  }

  function test_emergencyWithdraw_revertsZeroAmount() public {
    vm.prank(manager);
    vm.expectRevert(bytes("zero amount"));
    staking.emergencyWithdraw(address(lisAster), 0);
  }

  function test_emergencyWithdraw_onlyManager() public {
    bytes32 role = staking.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    staking.emergencyWithdraw(address(lisAster), 1);
  }
}
