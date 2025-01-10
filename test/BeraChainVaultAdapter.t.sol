// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

import "../src/BeraChainVaultAdapter.sol";
import "../src/token/NonTransferableLpERC20.sol";

contract BeraChainVaultAdapterTest is Test {
  address admin = address(0x1A11AA);
  address manager = address(0x1A11AB);
  address pauser = address(0x1A11AC);
  address bot = address(0x1A11AD);
  address receiver = address(0x1A11AE);
  address receiver1 = address(0x1A11AF);

  address user0 = address(0x1A11A0);
  address user1 = address(0x1A11A1);

  address proxyAdminOwner = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  IERC20 BTC;

  NonTransferableLpERC20 LPToken;

  BeraChainVaultAdapter adapter;

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.binance.org");

    BTC = IERC20(address(0xf9C4FF105803A77eCB5DAE300871Ad76c2794fa4));

    address lpProxy = Upgrades.deployUUPSProxy(
      "NonTransferableLpERC20.sol",
      abi.encodeCall(NonTransferableLpERC20.initialize, ("TestToken", "TEST"))
    );
    console.log("LP proxy address: %", lpProxy);
    address implAddress = Upgrades.getImplementationAddress(lpProxy);
    console.log("LP impl address: %s", implAddress);
    LPToken = NonTransferableLpERC20(lpProxy);

    address beraChainVaultProxy = Upgrades.deployUUPSProxy(
      "BeraChainVaultAdapter.sol",
      abi.encodeCall(
        BeraChainVaultAdapter.initialize,
        (admin, manager, pauser, bot, address(BTC), address(LPToken), receiver, block.timestamp + 1 days)
      )
    );
    console.log("BeraChainVaultAdapter proxy address: %", beraChainVaultProxy);
    address beraChainVaultImplAddress = Upgrades.getImplementationAddress(beraChainVaultProxy);
    console.log("BeraChainVaultAdapter impl address: %s", beraChainVaultImplAddress);
    adapter = BeraChainVaultAdapter(beraChainVaultProxy);

    LPToken.addMinter(beraChainVaultProxy);
  }

  function test_setUp() public {
    assertEq(address(adapter.token()), address(BTC));
    assertEq(address(adapter.lpToken()), address(LPToken));
    assertEq(adapter.operator(), receiver);
  }

  function test_deposit() public {
    deal(address(BTC), user0, 100 ether);

    vm.startPrank(user0);
    BTC.approve(address(adapter), 100 ether);
    adapter.deposit(100 ether);
    vm.stopPrank();

    assertEq(BTC.balanceOf(address(adapter)), 100 ether, "adapter BTC balance");
    assertEq(LPToken.balanceOf(address(user0)), 100 ether, "user0 LPToken balance");
    assertEq(BTC.balanceOf(address(user0)), 0, "user0 BTC balance");
  }

  function test_deposit_ended() public {
    deal(address(BTC), user0, 100 ether);

    skip(2 days);
    vm.startPrank(user0);
    vm.expectRevert("deposit closed");
    adapter.deposit(100 ether);
    vm.stopPrank();
  }

  function test_managerWithdraw() public {
    test_deposit();

    vm.startPrank(manager);
    adapter.managerWithdraw(receiver1, 91 ether);
    vm.stopPrank();

    assertEq(BTC.balanceOf(address(adapter)), 9 ether, "adapter BTC balance");
    assertEq(BTC.balanceOf(address(receiver1)), 91 ether, "receiver1 BTC balance");
    assertEq(LPToken.balanceOf(user0), 100 ether, "user0 LPToken balance");
  }

  function test_managerWithdraw_fail() public {
    test_deposit();

    vm.startPrank(manager);
    vm.expectRevert("insufficient balance");
    adapter.managerWithdraw(receiver1, 200 ether);
    vm.stopPrank();

    vm.startPrank(user0);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user0, keccak256("MANAGER"))
    );
    adapter.managerWithdraw(receiver1, 100 ether);
    vm.stopPrank();
  }

  function test_botWithdraw() public {
    test_deposit();

    vm.startPrank(bot);
    adapter.botWithdraw(91 ether);
    vm.stopPrank();

    assertEq(BTC.balanceOf(address(adapter)), 9 ether, "adapter BTC balance");
    assertEq(BTC.balanceOf(address(receiver)), 91 ether, "receiver BTC balance");
    assertEq(LPToken.balanceOf(user0), 100 ether, "user0 LPToken balance");
  }

  function test_botWithdraw_fail() public {
    test_deposit();

    vm.startPrank(bot);
    vm.expectRevert("insufficient balance");
    adapter.botWithdraw(200 ether);
    vm.stopPrank();

    vm.startPrank(user0);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user0, keccak256("BOT"))
    );
    adapter.botWithdraw(100 ether);
    vm.stopPrank();
  }

  function test_getUserLpBalance() public {
    assertEq(LPToken.balanceOf(user0), 0);

    test_deposit();

    assertEq(LPToken.balanceOf(user0), 100 ether);
  }

  function test_setOperator() public {
    assertEq(adapter.operator(), receiver);

    vm.startPrank(admin);
    adapter.setOperator(receiver1);
    vm.stopPrank();

    assertEq(adapter.operator(), receiver1);
  }
}
