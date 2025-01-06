// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/integration/BeraChainVaultAdapter.sol";
import "../../src/token/NonTransferableLpERC20.sol";

import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

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

  IERC20 PUMPBTC;

  NonTransferableLpERC20 LPToken;

  BeraChainVaultAdapter adapter;

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.binance.org");

    PUMPBTC = IERC20(address(0xf9C4FF105803A77eCB5DAE300871Ad76c2794fa4));
    TransparentUpgradeableProxy proxy0 = new TransparentUpgradeableProxy(
      address(new NonTransferableLpERC20()),
      proxyAdminOwner,
      abi.encodeWithSignature("initialize(string,string)", "TestToken", "TEST")
    );

    LPToken = NonTransferableLpERC20(payable(address(proxy0)));

    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new BeraChainVaultAdapter()),
      proxyAdminOwner,
      abi.encodeWithSignature(
        "initialize(address,address,address,address,address,address,address)",
        admin,
        manager,
        pauser,
        bot,
        address(PUMPBTC),
        address(LPToken),
        receiver
      )
    );

    adapter = BeraChainVaultAdapter(address(proxy));

    LPToken.addMinter(address(adapter));
  }

  function test_setUp() public {
    assertEq(address(adapter.token()), address(PUMPBTC));
    assertEq(address(adapter.lpToken()), address(LPToken));
    assertEq(adapter.botWithdrawReceiver(), receiver);
  }

  function test_deposit() public {
    deal(address(PUMPBTC), user0, 100 ether);

    vm.startPrank(user0);
    PUMPBTC.approve(address(adapter), 100 ether);
    adapter.deposit(100 ether);
    vm.stopPrank();

    assertEq(PUMPBTC.balanceOf(address(adapter)), 100 ether, "adapter PUMPBTC balance");
    assertEq(LPToken.balanceOf(address(user0)), 100 ether, "user0 LPToken balance");
    assertEq(PUMPBTC.balanceOf(address(user0)), 0, "user0 PUMPBTC balance");
  }

  function test_managerWithdraw() public {
    test_deposit();

    vm.startPrank(manager);
    adapter.managerWithdraw(receiver1, 91 ether);
    vm.stopPrank();

    assertEq(PUMPBTC.balanceOf(address(adapter)), 9 ether, "adapter PUMPBTC balance");
    assertEq(PUMPBTC.balanceOf(address(receiver1)), 91 ether, "receiver1 PUMPBTC balance");
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

    assertEq(PUMPBTC.balanceOf(address(adapter)), 9 ether, "adapter PUMPBTC balance");
    assertEq(PUMPBTC.balanceOf(address(receiver)), 91 ether, "receiver PUMPBTC balance");
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
}
