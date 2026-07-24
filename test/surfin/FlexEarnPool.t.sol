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
    flex.claimWithdraw(alice, 0);
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

  /* --------------------- A3: cancel does not refund quota --------------------- */

  function test_A3_cancelDoesNotRefundDailyQuota() public {
    vm.prank(manager);
    flex.setDailyLimit(200_000 ether);
    _depositFlex(alice, 500_000 ether);

    vm.prank(alice);
    flex.requestWithdraw(100_000 ether); // 100k of today's cap consumed

    vm.prank(alice);
    flex.cancelWithdraw(0); // restores LP, but the daily quota is NOT given back

    // 100k already counted + 150k new = 250k > 200k cap -> revert
    vm.prank(alice);
    vm.expectRevert("exceeds daily limit");
    flex.requestWithdraw(150_000 ether);
  }

  /* ----------------------- A4: cancel semantics ----------------------- */

  function test_A4_cancelRestoresLpAndMovesNoCash() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(40_000 ether);

    uint256 adapterBal = usdt.balanceOf(address(adapter));
    vm.prank(alice);
    flex.cancelWithdraw(0);

    assertEq(flex.balanceOf(alice), 100_000 ether, "LP fully restored");
    assertEq(flex.totalPendingWithdraw(), 0, "pending removed");
    assertEq(usdt.balanceOf(address(adapter)), adapterBal, "cancel moves no USDT");
    assertEq(usdt.balanceOf(alice), 0, "user receives nothing on cancel");
  }

  function test_A4_cancelConfirmedRequestReverts() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(40_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(40_000 ether); // batch 1 confirmed

    vm.prank(alice);
    vm.expectRevert("already confirmed");
    flex.cancelWithdraw(0);
  }

  function test_A4_claimBeforeConfirmationReverts() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(40_000 ether); // enqueued but unfunded

    vm.prank(alice);
    vm.expectRevert("not able to claim yet");
    flex.claimWithdraw(alice, 0);
  }
}
