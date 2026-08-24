// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/rwa/RWAEarnPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

  function test_finishWithdraw_zeroAmount_ticksBatchesUsingExistingQuota() public {
    USD1.mint(user, 2 ether);
    depositToEarnPool(user, 2 ether);

    // request 1: 0.5
    vm.startPrank(user);
    earnPool.requestWithdraw(0.5 ether, 0, user);
    vm.stopPrank();

    // first finishWithdraw with surplus quota that covers req1 + builds 0.5 leftover
    vm.startPrank(adapter);
    USD1.approve(address(earnPool), type(uint256).max);
    earnPool.finishWithdraw(1 ether);
    vm.stopPrank();
    assertEq(earnPool.confirmedBatchId(), 1, "first batch confirmed");
    assertEq(earnPool.withdrawQuota(), 0.5 ether, "leftover quota");

    // request 2 in a new batch — needs 0.5 which leftover quota can cover
    vm.warp(block.timestamp + 1 days);
    vm.startPrank(user);
    earnPool.requestWithdraw(0.5 ether, 0, user);
    vm.stopPrank();

    // calling with 0 must NOT revert and must tick batch 2 using leftover quota
    vm.startPrank(adapter);
    earnPool.finishWithdraw(0);
    vm.stopPrank();

    assertEq(earnPool.confirmedBatchId(), 2, "batch 2 confirmed via zero call");
    assertEq(earnPool.withdrawQuota(), 0, "quota fully consumed");
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

  /* ---------- ERC20 surface ---------- */

  function test_erc20Metadata() public view {
    assertEq(earnPool.name(), "USD1.Treasury", "name");
    assertEq(earnPool.symbol(), "USD1.Treasury", "symbol");
    assertEq(earnPool.decimals(), 18, "decimals");
    assertEq(IERC20(address(earnPool)).totalSupply(), 0, "usable via plain IERC20");
  }

  function test_transfer() public {
    address other = makeAddr("other");
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(user);
    vm.expectEmit(true, true, false, true);
    emit IERC20.Transfer(user, other, 0.4 ether);
    assertTrue(earnPool.transfer(other, 0.4 ether), "transfer return value");

    assertEq(earnPool.balanceOf(user), 0.6 ether, "sender shares");
    assertEq(earnPool.balanceOf(other), 0.4 ether, "receiver shares");
  }

  function test_transfer_isAccountingNeutral() public {
    address other = makeAddr("other");
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    uint256 supplyBefore = earnPool.totalSupply();
    uint256 assetsBefore = earnPool.totalAssets();
    uint256 userAssetsBefore = earnPool.userTotalAssets();

    vm.prank(user);
    earnPool.transfer(other, 0.4 ether);

    assertEq(earnPool.totalSupply(), supplyBefore, "totalSupply unchanged");
    assertEq(earnPool.totalAssets(), assetsBefore, "totalAssets unchanged");
    assertEq(earnPool.userTotalAssets(), userAssetsBefore, "userTotalAssets unchanged");
    assertEq(earnPool.balanceOf(user) + earnPool.balanceOf(other), supplyBefore, "shares conserved");
  }

  function test_transferredShares_areWithdrawable() public {
    address other = makeAddr("other");
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(user);
    earnPool.transfer(other, 0.4 ether);

    // the receiver never deposited, but can exit with what it was sent
    vm.prank(other);
    earnPool.requestWithdraw(0, 0.4 ether, other);

    assertEq(earnPool.balanceOf(other), 0, "receiver shares after requestWithdraw");

    RWAEarnPool.WithdrawalRequest[] memory requests = earnPool.getUserWithdrawalRequests(other);
    assertEq(requests.length, 1, "receiver withdrawal requests length");
    assertEq(requests[0].amount, 0.4 ether, "receiver withdrawal request amount");
  }

  function test_transfer_revertsOnInsufficientBalance() public {
    address other = makeAddr("other");
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(user);
    vm.expectRevert("transfer amount exceeds balance");
    earnPool.transfer(other, 1 ether + 1);
  }

  function test_transfer_revertsToZeroAddress() public {
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(user);
    vm.expectRevert("transfer to the zero address");
    earnPool.transfer(address(0), 1);
  }

  function test_transfer_revertsWhenPaused() public {
    address other = makeAddr("other");
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(pauser);
    earnPool.pause();

    vm.prank(user);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    earnPool.transfer(other, 1);
  }

  function test_transfer_receiverMustBeWhitelisted() public {
    address allowed = makeAddr("allowed");
    address blocked = makeAddr("blocked");

    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.startPrank(manager);
    earnPool.setWhiteList(user, true);
    earnPool.setWhiteList(allowed, true);
    vm.stopPrank();

    vm.startPrank(user);
    vm.expectRevert("receiver not in whitelist");
    earnPool.transfer(blocked, 1);

    earnPool.transfer(allowed, 1);
    vm.stopPrank();

    assertEq(earnPool.balanceOf(allowed), 1, "whitelisted receiver shares");
  }

  function test_transfer_senderNeedNotBeWhitelisted() public {
    address allowed = makeAddr("allowed");

    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    // user is left out of the whitelist on purpose: it must still send out and exit
    vm.prank(manager);
    earnPool.setWhiteList(allowed, true);

    vm.startPrank(user);
    earnPool.transfer(allowed, 0.4 ether);
    earnPool.requestWithdraw(0, 0.1 ether, user);
    vm.stopPrank();

    assertEq(earnPool.balanceOf(allowed), 0.4 ether, "receiver shares");
    assertEq(earnPool.balanceOf(user), 0.5 ether, "sender shares");
  }

  function test_approveAndTransferFrom() public {
    address spender = makeAddr("spender");
    address other = makeAddr("other");

    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(user);
    vm.expectEmit(true, true, false, true);
    emit IERC20.Approval(user, spender, 0.5 ether);
    assertTrue(earnPool.approve(spender, 0.5 ether), "approve return value");
    assertEq(earnPool.allowance(user, spender), 0.5 ether, "allowance");

    vm.prank(spender);
    assertTrue(earnPool.transferFrom(user, other, 0.2 ether), "transferFrom return value");

    assertEq(earnPool.allowance(user, spender), 0.3 ether, "allowance after spend");
    assertEq(earnPool.balanceOf(user), 0.8 ether, "owner shares");
    assertEq(earnPool.balanceOf(other), 0.2 ether, "receiver shares");
  }

  function test_transferFrom_infiniteAllowanceNotDecremented() public {
    address spender = makeAddr("spender");
    address other = makeAddr("other");

    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(user);
    earnPool.approve(spender, type(uint256).max);

    vm.prank(spender);
    earnPool.transferFrom(user, other, 0.2 ether);

    assertEq(earnPool.allowance(user, spender), type(uint256).max, "infinite allowance untouched");
  }

  function test_transferFrom_revertsOnInsufficientAllowance() public {
    address spender = makeAddr("spender");
    address other = makeAddr("other");

    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(user);
    earnPool.approve(spender, 0.1 ether);

    vm.prank(spender);
    vm.expectRevert("insufficient allowance");
    earnPool.transferFrom(user, other, 0.2 ether);
  }

  function test_transferFrom_respectsWhitelistAndPause() public {
    address spender = makeAddr("spender");
    address blocked = makeAddr("blocked");

    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(user);
    earnPool.approve(spender, 1 ether);

    vm.prank(manager);
    earnPool.setWhiteList(user, true);

    vm.prank(spender);
    vm.expectRevert("receiver not in whitelist");
    earnPool.transferFrom(user, blocked, 1);

    vm.prank(pauser);
    earnPool.pause();

    vm.prank(spender);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    earnPool.transferFrom(user, user, 1);
  }

  function test_approve_worksWhilePaused() public {
    address spender = makeAddr("spender");

    vm.prank(pauser);
    earnPool.pause();

    vm.startPrank(user);
    earnPool.approve(spender, 1 ether);
    assertEq(earnPool.allowance(user, spender), 1 ether, "allowance set while paused");
    earnPool.approve(spender, 0);
    assertEq(earnPool.allowance(user, spender), 0, "allowance revoked while paused");
    vm.stopPrank();
  }

  function test_approve_revertsToZeroAddress() public {
    vm.prank(user);
    vm.expectRevert("approve to the zero address");
    earnPool.approve(address(0), 1 ether);
  }

  function test_withdrawFeeShares_bypassWhitelist() public {
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.startPrank(manager);
    earnPool.setWithdrawFeeRate(0.1 ether); // 10%
    earnPool.setFeeReceiver(feeReceiver);
    // feeReceiver is intentionally NOT whitelisted
    earnPool.setWhiteList(user, true);
    vm.stopPrank();

    vm.prank(user);
    earnPool.requestWithdraw(0, 1 ether, user);

    assertEq(earnPool.balanceOf(feeReceiver), 0.1 ether, "fee shares reached a non-whitelisted feeReceiver");
  }
}
