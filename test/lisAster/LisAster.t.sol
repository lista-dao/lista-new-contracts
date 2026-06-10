// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LisAsterBase } from "./LisAsterBase.t.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

contract LisAsterTest is LisAsterBase {
  function test_initialState() public view {
    assertEq(lisAster.name(), "Lista Aster");
    assertEq(lisAster.symbol(), "lisAster");
    assertEq(lisAster.totalSupply(), 0);
    assertTrue(lisAster.hasRole(lisAster.DEFAULT_ADMIN_ROLE(), admin));
    assertTrue(lisAster.hasRole(lisAster.MINTER(), address(vault)));
    assertEq(lisAster.getRoleMemberCount(lisAster.MINTER()), 1, "MINTER unique");
  }

  function test_mint_revertsForNonMinter() public {
    bytes32 role = lisAster.MINTER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    lisAster.mint(user, 1 ether);
  }

  function test_burn_revertsForNonMinter() public {
    bytes32 role = lisAster.MINTER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    lisAster.burn(user, 1 ether);
  }

  function test_initializerCannotBeCalledTwice() public {
    vm.expectRevert(); // InvalidInitialization
    lisAster.initialize(admin, address(vault), "x", "y");
  }
}
