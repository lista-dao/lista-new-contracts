// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import "../../src/token/NonTransferableLpERC20.sol";

contract NonTransferableLpERC20Test is Test {
  address admin = address(0x1A11AA);
  address user0 = address(0x1A11A0);
  address user1 = address(0x1A11A1);

  address proxyAdminOwner = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  NonTransferableLpERC20 token;

  function setUp() public {
    address proxy = Upgrades.deployUUPSProxy(
      "NonTransferableLpERC20.sol",
      abi.encodeCall(NonTransferableLpERC20.initialize, ("TestToken", "TEST"))
    );
    console.log("NonTransferableLpERC20 proxy address: %", proxy);
    address implAddress = Upgrades.getImplementationAddress(proxy);
    console.log("NonTransferableLpERC20 impl address: %s", implAddress);

    token = NonTransferableLpERC20(proxy);
    token.addMinter(admin);
  }

  function test_setUp() public {
    assertEq(token.name(), "TestToken");
    assertEq(token.symbol(), "TEST");
    assertEq(token.owner(), address(this));
  }

  function test_mint() public {
    assertEq(token.balanceOf(user0), 0);

    vm.prank(admin);
    token.mint(user0, 123 ether);

    assertEq(token.balanceOf(user0), 123 ether);
  }

  function test_mint_acl() public {
    vm.prank(user0);
    vm.expectRevert("Minter: not allowed");
    token.mint(user0, 123 ether);
  }

  function test_burn() public {
    test_mint();

    vm.prank(admin);
    token.burn(user0, 123 ether);

    assertEq(token.balanceOf(user0), 0);
  }

  function test_burn_acl() public {
    test_mint();

    vm.prank(user0);
    vm.expectRevert("Minter: not allowed");
    token.mint(user0, 123 ether);

    assertEq(token.balanceOf(user0), 123 ether);
  }

  function test_transfer() public {
    test_mint();

    vm.prank(user0);
    vm.expectRevert("Not transferable");
    token.transfer(user1, 123 ether);
  }

  function test_transferFrom() public {
    test_mint();

    vm.prank(user1);
    vm.expectRevert("Not transferable");
    token.transferFrom(user0, user1, 123 ether);
  }

  function test_approve() public {
    test_mint();

    vm.prank(user0);
    vm.expectRevert("Not transferable");
    token.approve(user1, 123 ether);
  }
}
