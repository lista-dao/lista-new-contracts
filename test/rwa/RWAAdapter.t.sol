// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/rwa/RWAEarnPool.sol";
import "../../src/rwa/RWAAdapter.sol";
import "../../src/mock/MockAsyncVault.sol";
import "../../src/mock/MockERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/rwa/OTCManager.sol";

contract RWAAdapterTest is Test {
  MockERC20 USD1;
  MockERC20 USDC;
  MockERC20 shareToken;
  RWAAdapter adapter;
  RWAEarnPool earnPool;
  OTCManager otcManager;
  MockAsyncVault vault;

  address admin;
  address manager;
  address pauser;
  address bot;
  address user;
  address otcWallet;
  address feeReceiver;

  function setUp() public {
    admin = makeAddr("admin");
    user = makeAddr("user");
    manager = makeAddr("manager");
    pauser = makeAddr("pauser");
    bot = makeAddr("bot");
    otcWallet = makeAddr("otcWallet");
    feeReceiver = makeAddr("feeReceiver");

    USD1 = new MockERC20("USD1", "USD1");
    USDC = new MockERC20("USDC", "USDC");
    shareToken = new MockERC20("mUSD1", "mUSD1");

    vault = new MockAsyncVault(address(USDC), address(shareToken), 1e18);

    RWAEarnPool earnPoolImpl = new RWAEarnPool();
    RWAAdapter adapterImpl = new RWAAdapter(address(USD1), address(USDC));
    OTCManager otcManagerImpl = new OTCManager(address(USD1), address(USDC));

    earnPool = RWAEarnPool(address(new ERC1967Proxy(address(earnPoolImpl), "")));

    adapter = RWAAdapter(address(new ERC1967Proxy(address(adapterImpl), "")));

    otcManager = OTCManager(address(new ERC1967Proxy(address(otcManagerImpl), "")));

    earnPool.initialize(admin, manager, pauser, address(USD1), "USD1.Treasury", "USD1.Treasury", address(adapter));

    adapter.initialize(
      admin,
      manager,
      bot,
      address(earnPool),
      address(otcManager),
      address(vault),
      address(shareToken)
    );

    otcManager.initialize(admin, manager, bot, address(adapter), otcWallet);
  }

  function test_requestDepositToVault() public {
    USDC.mint(address(adapter), 1 ether);

    vm.startPrank(bot);
    adapter.requestDepositToVault(1 ether);
    vm.stopPrank();

    assertEq(USDC.balanceOf(address(adapter)), 0, "adapter USDC balance");
    assertEq(USDC.balanceOf(address(vault)), 1 ether, "vault USDC balance");
  }

  function test_depositToVault() public {
    USDC.mint(address(adapter), 1 ether);

    vm.startPrank(bot);
    adapter.requestDepositToVault(1 ether);
    adapter.depositToVault();
    vm.stopPrank();

    assertEq(USDC.balanceOf(address(adapter)), 0, "adapter USDC balance");
    assertEq(USDC.balanceOf(address(vault)), 1 ether, "vault USDC balance");
    assertEq(shareToken.balanceOf(address(adapter)), 1 ether, "adapter shareToken balance");
  }

  function test_depositRewards() public {
    USD1.mint(user, 1 ether);
    USDC.mint(manager, 1 ether);
    USDC.mint(address(adapter), 1 ether);

    vm.startPrank(user);
    USD1.approve(address(earnPool), 1 ether);
    earnPool.deposit(1 ether, 0, user);
    vm.stopPrank();

    vm.startPrank(manager);
    USDC.approve(address(adapter), 1 ether);
    adapter.depositRewards(1 ether);
    vm.stopPrank();

    vm.startPrank(bot);
    adapter.requestDepositToVault(1 ether);
    adapter.depositToVault();
    vm.stopPrank();

    skip(7 days);
    assertEq(earnPool.totalAssets(), 2 ether, "earnPool totalAssets");
    assertEq(shareToken.balanceOf(address(adapter)), 2 ether, "adapter shareToken balance");
  }

  function test_requestWithdrawFromVault() public {
    USDC.mint(address(adapter), 1 ether);

    vm.startPrank(bot);
    adapter.requestDepositToVault(1 ether);
    adapter.depositToVault();
    adapter.requestWithdrawFromVault(0.5 ether);
    vm.stopPrank();

    assertEq(USDC.balanceOf(address(adapter)), 0, "adapter USDC balance");
    assertEq(USDC.balanceOf(address(vault)), 1 ether, "vault USDC balance");
    assertEq(shareToken.balanceOf(address(adapter)), 0.5 ether, "adapter shareToken balance");
  }

  function test_withdrawFromVault() public {
    USDC.mint(address(adapter), 1 ether);

    vm.startPrank(bot);
    adapter.requestDepositToVault(1 ether);
    adapter.depositToVault();
    adapter.requestWithdrawFromVault(1 ether);
    adapter.withdrawFromVault(false);
    vm.stopPrank();

    assertEq(USDC.balanceOf(address(adapter)), 1 ether, "adapter USDC balance");
    assertEq(USDC.balanceOf(address(vault)), 0, "vault USDC balance");
    assertEq(shareToken.balanceOf(address(adapter)), 0, "adapter shareToken balance");

    USDC.mint(address(vault), 1 ether);

    vm.startPrank(manager);
    adapter.setFeeReceiver(feeReceiver);
    adapter.setFeeRate(0.1 ether);
    vm.stopPrank();

    vm.startPrank(bot);
    adapter.requestDepositToVault(1 ether);
    adapter.depositToVault();

    vault.setConvertRate(2 ether);

    adapter.requestWithdrawFromVault(2 ether);
    adapter.withdrawFromVault(true);
    vm.stopPrank();

    assertEq(USDC.balanceOf(address(adapter)), 1.9 ether, "adapter USDC balance after fee");
    assertEq(USDC.balanceOf(feeReceiver), 0.1 ether, "feeReceiver USDC balance after fee");
    assertEq(USDC.balanceOf(address(vault)), 0, "vault USDC balance after fee");
    assertEq(shareToken.balanceOf(address(adapter)), 0, "adapter shareToken balance after fee");
  }

  function test_finishEarnPoolWithdraw() public {
    USD1.mint(user, 1 ether);
    vm.startPrank(user);
    USD1.approve(address(earnPool), 1 ether);
    earnPool.deposit(1 ether, 0, user);
    earnPool.requestWithdraw(1 ether, 0, user);
    vm.stopPrank();

    vm.startPrank(bot);
    adapter.finishEarnPoolWithdraw(1 ether);
    vm.stopPrank();

    assertEq(USD1.balanceOf(address(earnPool)), 1 ether, "earnPool USD1 balance");
    assertEq(earnPool.confirmedBatchId(), 1, "earnPool confirmedBatchId");
    assertEq(USD1.balanceOf(address(adapter)), 0, "adapter USD1 balance");
  }

  function test_swapToken() public {
    USD1.mint(address(adapter), 1 ether);
    USDC.mint(address(adapter), 1 ether);

    vm.startPrank(bot);
    adapter.swapToken(address(USD1), 1 ether);
    adapter.swapToken(address(USDC), 1 ether);
    vm.stopPrank();

    assertEq(USD1.balanceOf(address(adapter)), 0, "adapter USD1 balance");
    assertEq(USDC.balanceOf(address(adapter)), 0, "adapter USDC balance");
    assertEq(USD1.balanceOf(otcWallet), 1 ether, "otcWallet USD1 balance");
    assertEq(USDC.balanceOf(otcWallet), 1 ether, "otcWallet USDC balance");
  }

  function test_updateVaultAssets() public {
    USDC.mint(address(adapter), 1 ether);
    USD1.mint(user, 1 ether);

    vm.startPrank(user);
    USD1.approve(address(earnPool), 1 ether);
    earnPool.deposit(1 ether, 0, user);
    vm.stopPrank();

    vm.startPrank(bot);
    adapter.requestDepositToVault(1 ether);
    adapter.depositToVault();
    vm.stopPrank();

    vault.setConvertRate(1.1 ether);

    vm.startPrank(bot);
    adapter.updateVaultAssets();
    vm.stopPrank();

    assertEq(adapter.lastVaultTotalAssets(), 1.1 ether, "adapter vaultAssets");
    assertEq(earnPool.totalAssets(), 1 ether, "earnPool totalAssets");

    skip(7 days);
    assertEq(earnPool.totalAssets(), 1.1 ether, "earnPool totalAssets after 7 days");
  }

  function test_setToUSDCLossRate() public {
    vm.startPrank(manager);
    adapter.setToUSDCLossRate(0.05 ether);
    vm.stopPrank();

    assertEq(adapter.toUSDCLossRate(), 0.05 ether, "toUSDCLossRate");
    assertEq(adapter.USD1ToUSDC(1 ether), 0.95 ether, "USD1ToUSDC");
  }

  function test_setToUSD1LossRate() public {
    vm.startPrank(manager);
    adapter.setToUSD1LossRate(0.05 ether);
    vm.stopPrank();

    assertEq(adapter.toUSD1LossRate(), 0.05 ether, "toUSD1LossRate");
    assertEq(adapter.USDCToUSD1(1 ether), 0.95 ether, "USDCToUSD1");
  }

  function test_depositRewardsBeforeDepositToVault() public {
    USDC.mint(manager, 1 ether);
    USD1.mint(user, 1 ether);

    // deposit 1 USD1 to earnPool
    vm.startPrank(user);
    USD1.approve(address(earnPool), 1 ether);
    earnPool.deposit(1 ether, 0, user);
    vm.stopPrank();

    // deposit 1 USDC as rewards to earnPool
    vm.startPrank(manager);
    USDC.approve(address(adapter), 1 ether);
    adapter.depositRewards(1 ether);
    vm.stopPrank();

    assertEq(earnPool.periodRewards(), 1 ether, "earnPool periodRewards");

    // deposit 1 USDC to vault
    USDC.mint(address(adapter), 1 ether);
    vm.startPrank(bot);
    adapter.requestDepositToVault(1 ether);
    adapter.depositToVault();
    vm.stopPrank();

    assertEq(earnPool.periodRewards(), 1 ether, "earnPool periodRewards");

    // deposit 1 USDC to vault again
    USDC.mint(address(adapter), 1 ether);
    vm.startPrank(bot);
    adapter.requestDepositToVault(1 ether);
    adapter.depositToVault();
    vm.stopPrank();

    assertEq(earnPool.periodRewards(), 1 ether, "earnPool periodRewards");
  }

  function test_newAssetLessThanOldAsset() public {
    USDC.mint(address(adapter), 1 ether);

    vm.startPrank(bot);
    adapter.requestDepositToVault(1 ether);
    adapter.depositToVault();
    vm.stopPrank();

    vault.setConvertRate(0.9 ether);

    vm.startPrank(bot);
    adapter.updateVaultAssets();
    vm.stopPrank();

    assertEq(adapter.lastVaultTotalAssets(), 1 ether, "adapter vaultAssets");
  }
}
