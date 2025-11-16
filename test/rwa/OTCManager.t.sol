// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/rwa/RWAEarnPool.sol";
import "../../src/rwa/RWAAdapter.sol";
import "../../src/mock/MockAsyncVault.sol";
import "../../src/mock/MockERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/rwa/OTCManager.sol";

contract OTCManagerTest is Test {
  MockERC20 USD1;
  MockERC20 USDC;
  OTCManager otcManager;

  address admin;
  address manager;
  address bot;
  address adapter;
  address otcWallet;
  function setUp() public {
    USD1 = new MockERC20("USD1", "USD1");
    USDC = new MockERC20("USDC", "USDC");

    admin = makeAddr("admin");
    manager = makeAddr("manager");
    bot = makeAddr("bot");
    adapter = makeAddr("adapter");
    otcWallet = makeAddr("otcWallet");

    OTCManager otcManagerImpl = new OTCManager(address(USD1), address(USDC));
    otcManager = OTCManager(
      address(
        new ERC1967Proxy(
          address(otcManagerImpl),
          abi.encodeWithSelector(otcManagerImpl.initialize.selector, admin, manager, bot, adapter, otcWallet)
        )
      )
    );
  }

  function test_swapToken() public {
    USD1.mint(adapter, 1 ether);
    USDC.mint(adapter, 1 ether);

    vm.startPrank(adapter);
    USD1.approve(address(otcManager), 1 ether);
    otcManager.swapToken(address(USD1), 1 ether);
    vm.stopPrank();

    assertEq(USD1.balanceOf(adapter), 0, "adapter USD1 balance");
    assertEq(USD1.balanceOf(otcWallet), 1 ether, "otcWallet USD1 balance");

    vm.startPrank(adapter);
    USDC.approve(address(otcManager), 1 ether);
    otcManager.swapToken(address(USDC), 1 ether);
    vm.stopPrank();

    assertEq(USDC.balanceOf(adapter), 0, "adapter USDC balance");
    assertEq(USDC.balanceOf(otcWallet), 1 ether, "otcWallet USDC balance");
  }

  function test_transferToAdapter() public {
    USD1.mint(address(otcManager), 1 ether);
    USDC.mint(address(otcManager), 1 ether);

    vm.startPrank(bot);
    otcManager.transferToAdapter(address(USD1), 1 ether);
    vm.stopPrank();

    assertEq(USD1.balanceOf(address(otcManager)), 0, "otcManager USD1 balance");
    assertEq(USD1.balanceOf(adapter), 1 ether, "adapter USD1 balance");

    vm.startPrank(bot);
    otcManager.transferToAdapter(address(USDC), 1 ether);
    vm.stopPrank();

    assertEq(USDC.balanceOf(address(otcManager)), 0, "otcManager USDC balance");
    assertEq(USDC.balanceOf(adapter), 1 ether, "adapter USDC balance");
  }
}
