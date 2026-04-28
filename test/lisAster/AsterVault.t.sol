// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LisAsterBase } from "./LisAsterBase.t.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract AsterVaultTest is LisAsterBase {
  function test_initialState() public view {
    assertEq(vault.asterToken(), address(asterToken));
    assertEq(vault.astherusVault(), address(astherusVault));
    assertEq(vault.lisAster(), address(lisAster));
    assertEq(vault.lisAsterManager(), lisAsterManager);
    assertEq(vault.broker(), 1);
    assertEq(vault.minDeposit(), 0.1 ether);
  }

  /* ---------------- deposit ---------------- */

  function test_deposit_atomicDepositAndMint() public {
    _giveAster(user, 1 ether);

    _userDeposit(user, 1 ether, user);

    // ASTER physical path: user -> Lista vault -> AstherusVault BSC contract.
    assertEq(asterToken.balanceOf(user), 0);
    assertEq(asterToken.balanceOf(address(vault)), 0, "vault holds no ASTER");
    assertEq(asterToken.balanceOf(address(astherusVault)), 1 ether);

    // AstherusVault saw exactly one depositFor(asterToken, lisAsterManager, 1 ether, broker=1).
    assertEq(astherusVault.callsLength(), 1);
    (address currency, address forAddress, uint256 amt, uint256 brk) = astherusVault.calls(0);
    assertEq(currency, address(asterToken));
    assertEq(forAddress, lisAsterManager, "forAddress = lisAsterManager");
    assertEq(amt, 1 ether);
    assertEq(brk, 1, "broker default 1");

    // 1:1 mint lisAster to receiver.
    assertEq(lisAster.balanceOf(user), 1 ether);
    assertEq(lisAster.totalSupply(), 1 ether);
  }

  function test_deposit_receiverCanDifferFromSender() public {
    _giveAster(user, 1 ether);

    vm.startPrank(user);
    asterToken.approve(address(vault), 1 ether);
    vault.deposit(1 ether, other);
    vm.stopPrank();

    assertEq(lisAster.balanceOf(user), 0);
    assertEq(lisAster.balanceOf(other), 1 ether);
  }

  function test_deposit_revertsBelowMinDeposit() public {
    _giveAster(user, 1 ether);
    vm.startPrank(user);
    asterToken.approve(address(vault), 0.05 ether);
    vm.expectRevert(bytes("amount < minDeposit"));
    vault.deposit(0.05 ether, user);
    vm.stopPrank();
  }

  function test_deposit_revertsZeroReceiver() public {
    _giveAster(user, 1 ether);
    vm.startPrank(user);
    asterToken.approve(address(vault), 1 ether);
    vm.expectRevert(bytes("receiver is zero"));
    vault.deposit(1 ether, address(0));
    vm.stopPrank();
  }

  function test_deposit_revertsWhenPaused() public {
    vm.prank(pauser);
    vault.pause();

    _giveAster(user, 1 ether);
    vm.startPrank(user);
    asterToken.approve(address(vault), 1 ether);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vault.deposit(1 ether, user);
    vm.stopPrank();
  }

  function test_deposit_brokerForwarded() public {
    vm.prank(admin);
    vault.setBroker(42);

    _giveAster(user, 1 ether);
    _userDeposit(user, 1 ether, user);

    (, , , uint256 brk) = astherusVault.calls(0);
    assertEq(brk, 42);
  }

  /* ---------------- no withdraw ---------------- */

  function test_noWithdrawSelectors() public view {
    // PRD forbids withdraw / redeem / emergencyWithdraw. They are absent at compile time;
    // this test exists as a regression guard so any future addition is caught explicitly.
    bytes4[3] memory forbidden = [
      bytes4(keccak256("withdraw(uint256)")),
      bytes4(keccak256("redeem(uint256)")),
      bytes4(keccak256("emergencyWithdraw(address)"))
    ];
    for (uint256 i = 0; i < forbidden.length; i++) {
      (bool ok, ) = address(vault).staticcall(abi.encodeWithSelector(forbidden[i]));
      assertFalse(ok, "forbidden selector exists");
    }
  }

  /* ---------------- admin ---------------- */

  function test_setBroker_onlyAdmin() public {
    bytes32 role = vault.DEFAULT_ADMIN_ROLE();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    vault.setBroker(2);

    vm.prank(admin);
    vault.setBroker(7);
    assertEq(vault.broker(), 7);
  }

  function test_setMinDeposit_onlyAdmin() public {
    vm.prank(admin);
    vault.setMinDeposit(2 ether);
    assertEq(vault.minDeposit(), 2 ether);
  }

  function test_pause_onlyPauser() public {
    bytes32 role = vault.PAUSER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    vault.pause();
  }

  function test_initializerCannotBeCalledTwice() public {
    vm.expectRevert();
    vault.initialize(
      admin,
      pauser,
      address(asterToken),
      address(astherusVault),
      address(lisAster),
      lisAsterManager,
      1,
      0
    );
  }
}
