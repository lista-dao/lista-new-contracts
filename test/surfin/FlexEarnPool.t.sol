// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";

/**
 * Test group 3 / module A — FlexEarnPool (demand product).
 *
 * Expectations are derived from the PRD, not from the implementation:
 *  - A1 face value: 1 LP == 1 USDT, funds custody at the adapter (§4.1)
 *  - A2 two-step withdraw + per-address daily submit cap (§4.5, §14.4)
 *  - A3 cancel does NOT refund the daily quota (§4.5)
 *  - A4 cancel only unlocks the LP, moves no cash; confirmed requests can't cancel (§4.5)
 */
contract FlexEarnPoolTest is SurfinTestBase {
  /* ---------- A8: the adapter can only be rewired on an empty pool ---------- */

  function test_A8_setAdapterRejectedWhilePrincipalIsLive() public {
    _depositFlex(alice, 100_000 ether);

    vm.prank(admin);
    vm.expectRevert("pool has live accounting");
    flex.setAdapter(makeAddr("otherAdapter"));
  }

  function test_A8_setAdapterRejectedWhileAWithdrawIsQueued() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(100_000 ether); // principal 0, but pending 100k

    assertEq(flex.totalPrincipal(), 0, "principal alone would have allowed it");
    vm.prank(admin);
    vm.expectRevert("pool has live accounting");
    flex.setAdapter(makeAddr("otherAdapter"));
  }

  function test_A8_setAdapterRejectedWhileQuotaSitsInThePool() public {
    // adminTopUp parks quota with no principal or queue behind it
    usdt.mint(admin, 1_000 ether);
    vm.startPrank(admin);
    usdt.approve(address(flex), 1_000 ether);
    flex.adminTopUp(1_000 ether);
    vm.stopPrank();

    assertEq(flex.totalPrincipal(), 0);
    assertEq(flex.totalPendingWithdraw(), 0);
    assertEq(flex.withdrawQuota(), 1_000 ether, "cash still sitting here");

    vm.prank(admin);
    vm.expectRevert("pool has live accounting");
    flex.setAdapter(makeAddr("otherAdapter"));
  }

  /// @dev the deploy-time rewire still works.
  function test_A8_setAdapterAllowedOnAFreshPool() public {
    address newAdapter = address(new MockAssetHolder(address(usdt)));
    vm.prank(admin);
    flex.setAdapter(newAdapter);
    assertEq(flex.adapter(), newAdapter, "rewire on an empty pool is the supported path");
  }

  /* ------------- A9: wiring must agree on the underlying asset ------------- */

  function test_A9_setAdapterRejectsAForeignAsset() public {
    MockERC20 other = new MockERC20("OTHER", "OTHER");
    address foreign = address(new MockAssetHolder(address(other)));

    vm.prank(admin);
    vm.expectRevert("adapter asset mismatch");
    flex.setAdapter(foreign);
  }

  /* ---------------- A6: the two withdraw limits must not cross ---------------- */

  /**
   * minWithdraw 500 against dailyLimit 100 leaves a 1,000 holder with no legal
   * amount: 500 breaks the cap, 100 breaks the floor, 1,000 breaks the cap. The dust
   * exit does not rescue them either, since draining also exceeds the cap. The setters
   * now refuse the crossing configuration from either direction.
   */
  function test_A6_limitsCannotCross() public {
    vm.startPrank(manager);

    flex.setDailyLimit(100 ether);
    vm.expectRevert("min above daily limit");
    flex.setMinWithdraw(500 ether);

    // and from the other side
    flex.setDailyLimit(1_000 ether);
    flex.setMinWithdraw(500 ether);
    vm.expectRevert("daily limit below min");
    flex.setDailyLimit(100 ether);

    vm.stopPrank();
    assertEq(flex.minWithdraw(), 500 ether, "rejected config was not applied");
    assertEq(flex.dailyLimit(), 1_000 ether);
  }

  /// @dev either limit may still be switched off independently.
  function test_A6_zeroDisablesEitherLimitIndependently() public {
    vm.startPrank(manager);
    flex.setDailyLimit(1_000 ether);
    flex.setMinWithdraw(500 ether);

    flex.setDailyLimit(0); // cap off, floor stays
    flex.setMinWithdraw(5_000 ether); // now unconstrained
    flex.setMinWithdraw(0); // floor off
    flex.setDailyLimit(100 ether); // cap back, unconstrained
    vm.stopPrank();

    assertEq(flex.minWithdraw(), 0);
    assertEq(flex.dailyLimit(), 100 ether);
  }

  /* --------------------------- A7: the dust exit --------------------------- */

  /// @dev a queued request can never come back as spendable balance, so the live
  ///      balance is a sound measure of "drains the position" and a sub-floor request
  ///      behind an earlier one is an honest exit.
  function test_A7_dustExitDrainsThePositionOrReverts() public {
    vm.prank(manager);
    flex.setMinWithdraw(50 ether);
    _depositFlex(alice, 100 ether);

    vm.prank(alice);
    flex.requestWithdraw(90 ether); // above the floor

    vm.prank(alice);
    flex.requestWithdraw(10 ether); // sub-floor but drains the balance -> allowed
    assertEq(flex.balanceOf(alice), 0, "position genuinely exited");
    assertEq(flex.totalPendingWithdraw(), 100 ether, "both requests queued");

    // a sub-floor request that leaves a remainder is still rejected
    _depositFlex(bob, 100 ether);
    vm.prank(bob);
    vm.expectRevert("below min withdraw");
    flex.requestWithdraw(9 ether);

    // a clean single dust exit with no queue at all works
    _depositFlex(charlie, 10 ether);
    vm.prank(charlie);
    flex.requestWithdraw(10 ether);
    assertEq(flex.balanceOf(charlie), 0);
  }

  /* ----------------------------- A1: deposit ----------------------------- */

  function test_A1_depositMints1to1AndForwardsToAdapter() public {
    _depositFlex(alice, 10_000 ether);

    assertEq(flex.balanceOf(alice), 10_000 ether, "1 LP == 1 USDT");
    assertEq(flex.totalSupply(), 10_000 ether, "supply tracks principal");
    assertEq(usdt.balanceOf(address(adapter)), 10_000 ether, "funds custody at the adapter");
    assertEq(usdt.balanceOf(address(flex)), 0, "pool holds accounting only");
  }

  function test_A1_depositBelowMinimumReverts() public {
    vm.prank(manager);
    flex.setMinDeposit(1_000 ether);

    usdt.mint(alice, 500 ether);
    vm.startPrank(alice);
    usdt.approve(address(flex), 500 ether);
    vm.expectRevert("deposit below minimum");
    flex.deposit(500 ether, alice);
    vm.stopPrank();
  }

  function test_A1_depositZeroReverts() public {
    vm.prank(alice);
    vm.expectRevert("amount is zero");
    flex.deposit(0, alice);
  }

  /* ------------------------- A2: two-step withdraw ------------------------- */

  function test_A2_withdrawTwoStepFlow() public {
    _depositFlex(alice, 100_000 ether);

    // step 1 — request: burns LP, enqueues, no cash moves to the user yet
    vm.prank(alice);
    flex.requestWithdraw(40_000 ether);
    assertEq(flex.balanceOf(alice), 60_000 ether, "LP burned on request");
    assertEq(flex.totalPendingWithdraw(), 40_000 ether, "request enqueued");
    assertEq(usdt.balanceOf(alice), 0, "no payout at request time");

    // step 2 — BOT funds the batch: cash lands in the pool, batch confirmed
    vm.prank(bot);
    adapter.finishFlexWithdraw(40_000 ether);
    assertEq(usdt.balanceOf(address(flex)), 40_000 ether, "cash sits in the pool awaiting claim");
    assertEq(flex.confirmedBatchId(), 1, "batch confirmed");
    assertEq(usdt.balanceOf(alice), 0, "still not in the wallet");

    // step 3 — claim: cash reaches the user wallet
    vm.prank(alice);
    flex.claimWithdraw(alice, 0, 40_000 ether);
    assertEq(usdt.balanceOf(alice), 40_000 ether, "claimed to wallet");
    assertEq(flex.totalPendingWithdraw(), 0, "pending cleared only on claim");
  }

  function test_A2_dailyLimitBoundary() public {
    vm.prank(manager);
    flex.setDailyLimit(200_000 ether);
    _depositFlex(alice, 500_000 ether);

    // exactly at the cap passes
    vm.prank(alice);
    flex.requestWithdraw(200_000 ether);

    // one wei over the same-day cap reverts
    vm.prank(alice);
    vm.expectRevert("exceeds daily limit");
    flex.requestWithdraw(1);
  }

  function test_A2_dailyLimitResetsNextUtcDay() public {
    vm.prank(manager);
    flex.setDailyLimit(200_000 ether);
    _depositFlex(alice, 500_000 ether);

    vm.prank(alice);
    flex.requestWithdraw(200_000 ether); // day D: cap consumed

    vm.warp(block.timestamp + 1 days); // cross into the next UTC day

    vm.prank(alice);
    flex.requestWithdraw(200_000 ether); // counter reset -> passes
    assertEq(flex.balanceOf(alice), 100_000 ether, "both days' requests cleared");
  }

  /* ------------------ A3: the daily cap counts submissions ------------------ */

  function test_A3_dailyCapAccumulatesAcrossRequests() public {
    vm.prank(manager);
    flex.setDailyLimit(200_000 ether);
    _depositFlex(alice, 500_000 ether);

    vm.prank(alice);
    flex.requestWithdraw(100_000 ether); // 100k of today's cap consumed

    // 100k already counted + 150k new = 250k > 200k cap -> revert
    vm.prank(alice);
    vm.expectRevert("exceeds daily limit");
    flex.requestWithdraw(150_000 ether);
  }

  /* ----------------------- A4: claim semantics ----------------------- */

  function test_A4_claimBeforeConfirmationReverts() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(40_000 ether); // enqueued but unfunded

    vm.prank(alice);
    vm.expectRevert("not able to claim yet");
    flex.claimWithdraw(alice, 0, 40_000 ether);
  }

  /// @dev the pool's rescue event names its receiver too.
  function test_A5_emergencyWithdrawEventCarriesReceiver() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(40_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(40_000 ether); // park cash in the pool

    address rescueTo = makeAddr("rescueTo");
    vm.expectEmit(true, true, false, true, address(flex));
    emit CreditFundBase.EmergencyWithdraw(address(usdt), rescueTo, 40_000 ether);

    vm.prank(admin);
    flex.emergencyWithdraw(address(usdt), 40_000 ether, rescueTo);
    assertEq(usdt.balanceOf(rescueTo), 40_000 ether, "funds reached the logged receiver");
  }
}

/// minimal stand-in for the adapter: the pool only reads `asset()` off it
contract MockAssetHolder {
  address public asset;

  constructor(address _asset) {
    asset = _asset;
  }
}
