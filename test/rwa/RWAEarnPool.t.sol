// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/rwa/RWAEarnPool.sol";
import "../../src/mock/MockAsyncVault.sol";
import "../../src/mock/MockERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RWAEarnPoolTest is Test {
  RWAEarnPool earnPool;
  MockERC20 USD1;
  address admin;
  address manager;
  address pauser;
  address adapter;
  address user;
  address feeReceiver;

  function setUp() public {
    admin = makeAddr("admin");
    user = makeAddr("user");
    manager = makeAddr("manager");
    pauser = makeAddr("pauser");
    adapter = makeAddr("adapter");
    USD1 = new MockERC20("USD1", "USD1");
    feeReceiver = makeAddr("feeReceiver");

    RWAEarnPool impl = new RWAEarnPool();
    earnPool = RWAEarnPool(
      address(
        new ERC1967Proxy(
          address(impl),
          abi.encodeWithSelector(
            impl.initialize.selector,
            admin,
            manager,
            pauser,
            address(USD1),
            "USD1.Treasury",
            "USD1.Treasury",
            adapter
          )
        )
      )
    );
  }

  function test_depositWithAmount() public {
    USD1.mint(user, 1 ether);

    depositToEarnPool(user, 1 ether);

    assertEq(USD1.balanceOf(user), 0, "user USD1 balance");
    assertEq(earnPool.balanceOf(user), 1 ether, "user earnPool shares");
    assertEq(USD1.balanceOf(adapter), 1 ether, "adapter USD1 balance");
  }

  function test_depositWithShares() public {
    USD1.mint(user, 1 ether);

    depositToEarnPool(user, 1 ether);

    assertEq(USD1.balanceOf(user), 0, "user USD1 balance");
    assertEq(earnPool.balanceOf(user), 1 ether, "user earnPool shares");
    assertEq(USD1.balanceOf(adapter), 1 ether, "adapter USD1 balance");
  }

  function test_requestWithdraw() public {
    USD1.mint(user, 1 ether);

    depositToEarnPool(user, 1 ether);

    vm.startPrank(user);
    earnPool.requestWithdraw(1 ether, 0, user);
    vm.stopPrank();

    assertEq(earnPool.balanceOf(user), 0, "user earnPool shares after requestWithdraw");

    RWAEarnPool.WithdrawalRequest[] memory requests = earnPool.getUserWithdrawalRequests(user);

    assertEq(requests.length, 1, "user withdrawal requests length");
    assertEq(requests[0].amount, 1 ether, "user withdrawal request shares");
  }

  function test_finishWithdraw() public {
    USD1.mint(user, 1 ether);

    depositToEarnPool(user, 1 ether);

    vm.startPrank(user);
    earnPool.requestWithdraw(0.5 ether, 0, user);
    vm.stopPrank();

    vm.startPrank(adapter);
    USD1.approve(address(earnPool), type(uint256).max);
    earnPool.finishWithdraw(0.5 ether);
    vm.stopPrank();

    assertEq(USD1.balanceOf(address(earnPool)), 0.5 ether, "earnPool USD1 balance after finishWithdraw");
    assertEq(USD1.balanceOf(adapter), 0.5 ether, "adapter USD1 balance after finishWithdraw");
    assertEq(earnPool.confirmedBatchId(), 1, "earnPool confirmedBatchId after finishWithdraw");

    vm.startPrank(user);
    earnPool.requestWithdraw(0.5 ether, 0, user);
    vm.stopPrank();

    vm.startPrank(adapter);
    earnPool.finishWithdraw(0.5 ether);
    vm.stopPrank();

    assertEq(USD1.balanceOf(address(earnPool)), 1 ether, "earnPool USD1 balance after finishWithdraw");
    assertEq(USD1.balanceOf(adapter), 0 ether, "adapter USD1 balance after finishWithdraw");
    assertEq(earnPool.confirmedBatchId(), 2, "earnPool confirmedBatchId after finishWithdraw");
  }

  function test_claimWithdraw() public {
    USD1.mint(user, 1 ether);

    depositToEarnPool(user, 1 ether);

    vm.startPrank(user);
    earnPool.requestWithdraw(1 ether, 0, user);
    vm.stopPrank();

    vm.startPrank(adapter);
    USD1.approve(address(earnPool), type(uint256).max);
    earnPool.finishWithdraw(1 ether);
    vm.stopPrank();

    vm.startPrank(user);
    earnPool.claimWithdraw(user, 0);
    vm.stopPrank();

    assertEq(USD1.balanceOf(user), 1 ether, "user USD1 balance after claimWithdraw");
    assertEq(earnPool.balanceOf(user), 0, "user earnPool shares after claimWithdraw");
    assertEq(USD1.balanceOf(address(earnPool)), 0, "earnPool USD1 balance after claimWithdraw");

    RWAEarnPool.WithdrawalRequest[] memory requests = earnPool.getUserWithdrawalRequests(user);
    assertEq(requests.length, 0, "user withdrawal requests length");
  }

  function test_notifyInterest() public {
    USD1.mint(user, 1 ether);

    depositToEarnPool(user, 1 ether);

    vm.startPrank(adapter);
    earnPool.notifyInterest(0.7 ether);
    vm.stopPrank();

    skip(1 days);
    assertEq(earnPool.totalAssets(), 1.1 ether, "earnPool totalAssets after notifyInterest 1 days");
    assertEq(earnPool.getUnvestedAmount(), 0.6 ether, "earnPool unvestAmount after notifyInterest 1 days");

    skip(7 days);
    assertEq(earnPool.totalAssets(), 1.7 ether, "earnPool totalAssets after notifyInterest 7 days");
    assertEq(earnPool.getUnvestedAmount(), 0, "earnPool unvestAmount after notifyInterest 7 days");

    skip(8 days);
    assertEq(earnPool.totalAssets(), 1.7 ether, "earnPool totalAssets after notifyInterest 8 days");
    assertEq(earnPool.getUnvestedAmount(), 0, "earnPool unvestAmount after notifyInterest 8 days");
  }

  function test_setWhitelist() public {
    USD1.mint(user, 1 ether);
    USD1.mint(address(this), 1 ether);

    vm.startPrank(manager);
    earnPool.setWhiteList(user, true);
    vm.stopPrank();

    depositToEarnPool(user, 1 ether);

    USD1.approve(address(earnPool), type(uint256).max);
    vm.expectRevert("receiver not in whitelist");
    earnPool.deposit(1 ether, 0, address(this));

    address[] memory whitelists = earnPool.getWhiteList();
    assertEq(whitelists.length, 1, "whitelist length");
    assertEq(whitelists[0], user, "whitelist address");
    assertEq(earnPool.isInWhitelist(user), true, "is user in whitelist");
  }

  function test_fee() public {
    USD1.mint(user, 1 ether);

    depositToEarnPool(user, 1 ether);

    vm.startPrank(manager);
    earnPool.setWithdrawFeeRate(0.1 ether); // 10%
    earnPool.setFeeReceiver(feeReceiver);
    vm.stopPrank();

    vm.startPrank(user);
    earnPool.requestWithdraw(1 ether, 0, user);
    vm.stopPrank();

    assertEq(earnPool.balanceOf(user), 0, "user earnPool shares after requestWithdraw");
    assertEq(earnPool.balanceOf(feeReceiver), 0.1 ether, "feeReceiver earnPool shares after requestWithdraw");

    RWAEarnPool.WithdrawalRequest[] memory requests = earnPool.getUserWithdrawalRequests(user);
    assertEq(requests[0].amount, 0.9 ether, "user withdrawal request shares after fee");
  }

  function depositToEarnPool(address _user, uint256 amount) private {
    vm.startPrank(_user);
    USD1.approve(address(earnPool), type(uint256).max);
    earnPool.deposit(amount, 0, _user);
    vm.stopPrank();
  }

  function test_withdrawMoreThanDeposit() public {
    USD1.mint(user, 1 ether);

    depositToEarnPool(user, 1 ether);

    vm.startPrank(adapter);
    earnPool.notifyInterest(1 ether);
    vm.stopPrank();

    skip(7 days);

    vm.startPrank(user);
    earnPool.requestWithdraw(0, 1 ether, user);
    vm.stopPrank();

    assertEq(earnPool.balanceOf(user), 0, "user earnPool shares after requestWithdraw");

    RWAEarnPool.WithdrawalRequest[] memory requests = earnPool.getUserWithdrawalRequests(user);

    assertEq(requests.length, 1, "user withdrawal requests length");
    assertEq(requests[0].amount, 2 ether - 1, "user withdrawal request shares");
  }

  function test_requestWithdrawWithoutShares() public {
    USD1.mint(user, 1);

    depositToEarnPool(user, 1);

    vm.startPrank(user);
    earnPool.requestWithdraw(1, 0, user);
    vm.stopPrank();

    assertEq(earnPool.balanceOf(user), 0, "user earnPool shares after requestWithdraw");
  }

  function test_setMinDeposit_onlyManager() public {
    vm.expectRevert();
    earnPool.setMinDeposit(1000 ether);

    vm.startPrank(manager);
    vm.expectEmit(false, false, false, true);
    emit RWAEarnPool.SetMinDeposit(1000 ether);
    earnPool.setMinDeposit(1000 ether);
    assertEq(earnPool.minDeposit(), 1000 ether, "minDeposit");

    vm.expectRevert("same minDeposit");
    earnPool.setMinDeposit(1000 ether);
    vm.stopPrank();
  }

  function test_deposit_revertsBelowMin_byAmount() public {
    vm.startPrank(manager);
    earnPool.setMinDeposit(1000 ether);
    vm.stopPrank();

    USD1.mint(user, 2000 ether);

    vm.startPrank(user);
    USD1.approve(address(earnPool), type(uint256).max);
    vm.expectRevert("deposit below minimum");
    earnPool.deposit(999 ether, 0, user);

    // boundary: equal to min passes
    earnPool.deposit(1000 ether, 0, user);
    vm.stopPrank();

    assertEq(earnPool.balanceOf(user), 1000 ether, "user shares");
  }

  function test_deposit_revertsBelowMin_byShares() public {
    // first seed pool with one large deposit so shares-based path has meaningful conversion
    USD1.mint(user, 2000 ether);
    depositToEarnPool(user, 2000 ether);

    vm.startPrank(manager);
    earnPool.setMinDeposit(1000 ether);
    vm.stopPrank();

    address other = makeAddr("other");
    USD1.mint(other, 2000 ether);

    vm.startPrank(other);
    USD1.approve(address(earnPool), type(uint256).max);
    // 999 shares -> ~999 amount, below min, must revert (proves shares path is also gated)
    vm.expectRevert("deposit below minimum");
    earnPool.deposit(0, 999 ether, other);
    vm.stopPrank();
  }

  function test_deposit_zeroMin_backwardCompat() public {
    // default minDeposit == 0, small deposits still allowed
    USD1.mint(user, 1);
    depositToEarnPool(user, 1);
    assertEq(earnPool.balanceOf(user), 1, "user shares");
  }

  function test_withdrawAllFee() public {
    USD1.mint(user, 1 ether);

    depositToEarnPool(user, 1 ether);

    vm.startPrank(manager);
    earnPool.setWithdrawFeeRate(0.1 ether); // 10%
    earnPool.setFeeReceiver(feeReceiver);
    vm.stopPrank();

    vm.startPrank(user);
    earnPool.requestWithdraw(0, 1 ether, user);
    vm.stopPrank();

    assertEq(earnPool.balanceOf(user), 0, "user earnPool shares after requestWithdraw");
    assertEq(earnPool.balanceOf(feeReceiver), 0.1 ether, "feeReceiver earnPool shares after requestWithdraw");

    vm.startPrank(feeReceiver);
    earnPool.requestWithdraw(0, 0.1 ether, feeReceiver);
    vm.stopPrank();

    assertEq(earnPool.balanceOf(feeReceiver), 0, "feeReceiver earnPool shares after requestWithdraw");
  }
}
