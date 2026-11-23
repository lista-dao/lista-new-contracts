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

  /* ---------------- wind-down: deposit switch ---------------- */

  function test_setDepositPaused_onlyManager() public {
    vm.expectRevert();
    earnPool.setDepositPaused(true);

    vm.startPrank(manager);
    vm.expectEmit(false, false, false, true);
    emit RWAEarnPool.SetDepositPaused(true);
    earnPool.setDepositPaused(true);
    assertTrue(earnPool.depositPaused(), "depositPaused");

    vm.expectRevert("same status");
    earnPool.setDepositPaused(true);

    earnPool.setDepositPaused(false);
    assertFalse(earnPool.depositPaused(), "depositPaused reopened");
    vm.stopPrank();
  }

  function test_depositPaused_blocksDeposit_butUsersCanStillExit() public {
    address other = makeAddr("other");
    USD1.mint(user, 2 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(manager);
    earnPool.setDepositPaused(true);

    // deposits are closed, by amount and by shares
    vm.startPrank(user);
    vm.expectRevert("deposit paused");
    earnPool.deposit(1 ether, 0, user);
    vm.expectRevert("deposit paused");
    earnPool.deposit(0, 1 ether, user);

    // ...but the exit path is untouched: transfer, requestWithdraw, claimWithdraw
    earnPool.transfer(other, 0.2 ether);
    earnPool.requestWithdraw(0, 0.8 ether, user);
    vm.stopPrank();
    assertEq(earnPool.balanceOf(user), 0, "user shares after exit");
    assertEq(earnPool.balanceOf(other), 0.2 ether, "other shares after transfer");

    vm.startPrank(adapter);
    USD1.approve(address(earnPool), type(uint256).max);
    earnPool.finishWithdraw(0.8 ether);
    vm.stopPrank();

    earnPool.claimWithdraw(user, 0);
    assertEq(USD1.balanceOf(user), 1.8 ether, "user USD1 after claim (1 unspent + 0.8 withdrawn)");

    // reopening lets deposits through again
    vm.prank(manager);
    earnPool.setDepositPaused(false);
    depositToEarnPool(user, 1 ether);
    assertEq(earnPool.balanceOf(user), 1 ether, "user shares after redeposit");
  }

  /* ---------------- wind-down: BOT withdrawFor ---------------- */

  function _grantBot() private returns (address bot) {
    bot = makeAddr("bot");
    bytes32 botRole = earnPool.BOT(); // read before the prank: a staticcall would consume it
    vm.prank(admin);
    earnPool.grantRole(botRole, bot);
  }

  function _one(address a) private pure returns (address[] memory users) {
    users = new address[](1);
    users[0] = a;
  }

  function test_withdrawFor_onlyBot() public {
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);
    vm.prank(manager);
    earnPool.setDepositPaused(true);

    // neither a random caller, the manager nor the admin may force exits
    vm.expectRevert();
    earnPool.withdrawFor(_one(user));
    vm.prank(manager);
    vm.expectRevert();
    earnPool.withdrawFor(_one(user));
    vm.prank(admin);
    vm.expectRevert();
    earnPool.withdrawFor(_one(user));
    assertEq(earnPool.balanceOf(user), 1 ether, "user shares untouched");
  }

  function test_withdrawFor_requiresDepositPaused() public {
    address bot = _grantBot();
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);

    vm.prank(bot);
    vm.expectRevert("deposit not paused");
    earnPool.withdrawFor(_one(user));
  }

  function test_withdrawFor_emptyOrShareLessList_isNoop() public {
    address bot = _grantBot();
    vm.prank(manager);
    earnPool.setDepositPaused(true);
    uint256 batchBefore = earnPool.currentBatchId();

    vm.startPrank(bot);
    earnPool.withdrawFor(new address[](0));
    earnPool.withdrawFor(_one(makeAddr("empty")));
    vm.stopPrank();

    assertEq(earnPool.currentBatchId(), batchBefore, "no batch opened for nothing");
    assertEq(earnPool.getUserWithdrawalRequests(makeAddr("empty")).length, 0, "no request queued");
  }

  function test_withdrawFor_revertsWhenPaused() public {
    address bot = _grantBot();
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);
    vm.prank(manager);
    earnPool.setDepositPaused(true);
    vm.prank(pauser);
    earnPool.pause();

    vm.prank(bot);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    earnPool.withdrawFor(_one(user));
  }

  function test_withdrawFor_exitsEveryUser_noFee_skipsEmpty() public {
    address bot = _grantBot();
    address user2 = makeAddr("user2");
    address empty = makeAddr("empty");
    USD1.mint(user, 1 ether);
    USD1.mint(user2, 2 ether);
    depositToEarnPool(user, 1 ether);
    depositToEarnPool(user2, 2 ether);

    // accrue interest so shares != assets, and switch on a withdraw fee that must NOT apply
    vm.prank(adapter);
    earnPool.notifyInterest(0.3 ether);
    skip(7 days);
    vm.startPrank(manager);
    earnPool.setWithdrawFeeRate(0.1 ether);
    earnPool.setFeeReceiver(feeReceiver);
    earnPool.setDepositPaused(true);
    vm.stopPrank();

    uint256 sharesUser = earnPool.balanceOf(user);
    uint256 sharesUser2 = earnPool.balanceOf(user2);
    uint256 expectUser = earnPool.convertToAssets(sharesUser);
    assertGt(expectUser, 1 ether, "user is owed principal + interest");

    address[] memory users = new address[](4);
    users[0] = user;
    users[1] = empty; // no shares: skipped, not reverted
    users[2] = user2;
    users[3] = user; // duplicate: already exited, skipped

    vm.expectEmit(false, false, false, true);
    emit RWAEarnPool.RequestWithdraw(user, user, 1, sharesUser, expectUser, 0);
    vm.prank(bot);
    earnPool.withdrawFor(users);

    // all shares burnt, nothing skimmed to the fee receiver
    assertEq(earnPool.balanceOf(user), 0, "user shares");
    assertEq(earnPool.balanceOf(user2), 0, "user2 shares");
    assertEq(earnPool.balanceOf(feeReceiver), 0, "no fee shares on forced exit");
    assertEq(earnPool.totalSupply(), 0, "totalSupply");
    assertLe(earnPool.userTotalAssets(), 2, "userTotalAssets drained up to rounding dust");

    // one request each, in the same batch, addressed to the user themself
    RWAEarnPool.WithdrawalRequest[] memory r1 = earnPool.getUserWithdrawalRequests(user);
    RWAEarnPool.WithdrawalRequest[] memory r2 = earnPool.getUserWithdrawalRequests(user2);
    assertEq(r1.length, 1, "user request count (duplicate ignored)");
    assertEq(r2.length, 1, "user2 request count");
    assertEq(earnPool.getUserWithdrawalRequests(empty).length, 0, "empty user has no request");
    assertEq(r1[0].amount, expectUser, "user request amount");
    assertApproxEqAbs(r2[0].amount, 2 * expectUser, 2, "user2 holds twice the shares");
    assertEq(r1[0].batchId, earnPool.currentBatchId(), "user batch");
    assertEq(r2[0].batchId, earnPool.currentBatchId(), "user2 batch");
    uint256 batchTotal = earnPool.totalWithdrawAmountInBatch(earnPool.currentBatchId());
    assertEq(batchTotal, r1[0].amount + r2[0].amount, "batch total");
    assertLe(batchTotal, 3.3 ether, "never more than deposits + interest");

    // settle through the normal adapter path, then the BOT claims on the users' behalf
    USD1.mint(adapter, 1 ether); // interest the adapter would have pulled back from the vault
    vm.startPrank(adapter);
    USD1.approve(address(earnPool), type(uint256).max);
    earnPool.finishWithdraw(batchTotal);
    vm.stopPrank();
    assertEq(earnPool.confirmedBatchId(), earnPool.currentBatchId(), "batch confirmed");

    vm.startPrank(bot);
    earnPool.claimWithdraw(user, 0);
    earnPool.claimWithdraw(user2, 0);
    vm.stopPrank();
    assertEq(USD1.balanceOf(user), r1[0].amount, "user received principal + interest");
    assertEq(USD1.balanceOf(user2), r2[0].amount, "user2 received principal + interest");
    assertEq(USD1.balanceOf(bot), 0, "bot received nothing");
  }

  function test_withdrawFor_matchesUserRequestWithdraw_whenNoFee() public {
    address bot = _grantBot();
    address user2 = makeAddr("user2");
    USD1.mint(user, 1 ether);
    USD1.mint(user2, 1 ether);
    depositToEarnPool(user, 1 ether);
    depositToEarnPool(user2, 1 ether);
    vm.prank(adapter);
    earnPool.notifyInterest(0.5 ether);
    skip(7 days);
    vm.prank(manager);
    earnPool.setDepositPaused(true);

    // user exits themself, bot exits user2 in the same block: same payout up to rounding, same batch
    vm.prank(user);
    earnPool.requestWithdraw(0, 1 ether, user);
    vm.prank(bot);
    earnPool.withdrawFor(_one(user2));

    RWAEarnPool.WithdrawalRequest[] memory r1 = earnPool.getUserWithdrawalRequests(user);
    RWAEarnPool.WithdrawalRequest[] memory r2 = earnPool.getUserWithdrawalRequests(user2);
    assertApproxEqAbs(r1[0].amount, r2[0].amount, 1, "same payout");
    assertEq(r1[0].batchId, r2[0].batchId, "same batch");
  }

  function test_withdrawFor_keepsEarlierRequests() public {
    address bot = _grantBot();
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);
    vm.prank(manager);
    earnPool.setDepositPaused(true);

    // the user asked for part of it and never claimed; the bot exits the rest
    vm.prank(user);
    earnPool.requestWithdraw(0, 0.4 ether, user);
    vm.prank(bot);
    earnPool.withdrawFor(_one(user));

    RWAEarnPool.WithdrawalRequest[] memory r = earnPool.getUserWithdrawalRequests(user);
    assertEq(r.length, 2, "old request kept, new one appended");
    assertEq(r[0].amount, 0.4 ether, "old request");
    assertEq(r[1].amount, 0.6 ether, "forced request covers the rest");
    assertEq(earnPool.balanceOf(user), 0, "no shares left");

    vm.startPrank(adapter);
    USD1.approve(address(earnPool), type(uint256).max);
    earnPool.finishWithdraw(1 ether);
    vm.stopPrank();

    // anyone can claim both for the user; claiming idx 0 moves the last request into its place
    earnPool.claimWithdraw(user, 0);
    earnPool.claimWithdraw(user, 0);
    assertEq(USD1.balanceOf(user), 1 ether, "user received everything");
    assertEq(earnPool.getUserWithdrawalRequests(user).length, 0, "no requests left");
  }

  function test_withdrawFor_exitsTheFeeReceiver() public {
    address bot = _grantBot();
    USD1.mint(user, 1 ether);
    depositToEarnPool(user, 1 ether);
    vm.startPrank(manager);
    earnPool.setWithdrawFeeRate(0.1 ether);
    earnPool.setFeeReceiver(feeReceiver);
    earnPool.setDepositPaused(true);
    vm.stopPrank();

    // a user exit leaves fee shares on the fee receiver, which may be a contract that cannot request
    vm.prank(user);
    earnPool.requestWithdraw(0, 1 ether, user);
    assertEq(earnPool.balanceOf(feeReceiver), 0.1 ether, "fee shares");

    vm.prank(bot);
    earnPool.withdrawFor(_one(feeReceiver));
    assertEq(earnPool.balanceOf(feeReceiver), 0, "fee shares burnt");
    assertEq(earnPool.totalSupply(), 0, "totalSupply");

    vm.startPrank(adapter);
    USD1.approve(address(earnPool), type(uint256).max);
    earnPool.finishWithdraw(1 ether);
    vm.stopPrank();
    earnPool.claimWithdraw(feeReceiver, 0);
    earnPool.claimWithdraw(user, 0);
    assertEq(USD1.balanceOf(feeReceiver), 0.1 ether, "fee receiver paid in the asset");
    assertEq(USD1.balanceOf(user), 0.9 ether, "user paid net of the fee");
  }
}
