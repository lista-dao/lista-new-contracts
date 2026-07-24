// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";
import "../../src/surfin/CreditFundBase.sol";

/**
 * Test group 3 / module B — LockedEarnPool (term product).
 *
 * PRD-derived expectations:
 *  - B1 early-redeem penalty is computed on-chain (§4.4); flat rate on redeemed
 *       principal inside the 30-day window, full principal past it; partial allowed
 *  - B2 early-redeem is irreversible — no cancel entrypoint (§4.4)
 *  - B3 the locked daily submit counter is independent from flex (§14.4)
 *  - B4 matured withdrawal has no penalty and is exempt from the daily cap (§4.3)
 *  - B5 auto-renew rolls principal only and is capped at one term (§4.3)
 *  - B6 auto-renew toggle is locked inside the T-window before maturity (§4.3)
 *  - B7 one-click reinvest rolls a funded payout into a new cohort (§4.3)
 *  - B8 setCohort maturity guardrail bounds the settlement alignment (§4.3)
 *
 * NOTE: the contract's early-redeem model is a flat penalty on principal, which is
 * simpler than the PRD's base-interest-offset model (see SurfinConflict CONFLICT-2).
 * These tests pin the contract's actual flat-penalty math.
 */
contract LockedEarnPoolTest is SurfinTestBase {
  uint256 constant T0 = 1_000_000;

  function _openCohort(uint256 id) internal {
    _setCohort(id, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
  }

  /* ----------------------------- B1: early redeem ----------------------------- */

  function test_B1_earlyRedeemFlatPenaltyWithinWindow() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, false);

    vm.warp(block.timestamp + 10 days); // still inside the 30-day penalty window
    uint256 payout = locked.previewEarlyRedeem(alice, 0, 50_000 ether);
    assertEq(payout, 49_600 ether, "flat 0.8% penalty (50,000 * 0.008 = 400)");

    vm.prank(alice);
    locked.requestEarlyRedeem(0, 50_000 ether);

    assertEq(locked.totalPendingWithdraw(), 49_600 ether, "penalized payout queued");
    LockedEarnPool.Position[] memory pos = locked.getUserPositions(alice);
    assertEq(pos[0].principal, 0, "principal fully redeemed");
    assertTrue(pos[0].closed, "position closed");
    assertEq(locked.totalPrincipalAmount(), 0, "book principal removed");
  }

  function test_B1_earlyRedeemNoPenaltyPastWindow() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, false);

    vm.warp(block.timestamp + 30 days); // exactly at the window edge -> no penalty
    uint256 payout = locked.previewEarlyRedeem(alice, 0, 50_000 ether);
    assertEq(payout, 50_000 ether, "full principal returned at/after the window edge");
  }

  function test_B1_partialEarlyRedeemSplitsPosition() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, false);

    vm.warp(block.timestamp + 10 days);
    vm.prank(alice);
    locked.requestEarlyRedeem(0, 20_000 ether); // partial

    LockedEarnPool.Position[] memory pos = locked.getUserPositions(alice);
    assertEq(pos[0].principal, 30_000 ether, "remaining principal stays in the position");
    assertFalse(pos[0].closed, "position still open");
    assertEq(locked.totalPrincipalAmount(), 30_000 ether, "book reduced by redeemed part only");
    assertEq(locked.totalPendingWithdraw(), 19_840 ether, "20,000 * 0.992 = 19,840 queued");
  }

  function test_B1_earlyRedeemAfterMaturityReverts() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, false);

    vm.warp(block.timestamp + 92 days); // past maturity
    vm.prank(alice);
    vm.expectRevert("already matured");
    locked.requestEarlyRedeem(0, 50_000 ether);
  }

  /* --------------------- B2: early redeem is irreversible --------------------- */

  function test_B2_earlyRedeemIsIrreversibleNoCancelEntrypoint() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, false);

    vm.warp(block.timestamp + 10 days);
    vm.prank(alice);
    locked.requestEarlyRedeem(0, 50_000 ether);

    // Unlike FlexEarnPool, LockedEarnPool exposes no cancelWithdraw. The position is
    // closed and the queued payout can only be consumed via claimWithdraw after
    // funding — there is no path to reopen the position or reclaim the principal.
    LockedEarnPool.Position[] memory pos = locked.getUserPositions(alice);
    assertTrue(pos[0].closed, "position permanently closed");
    CreditFundBase.WithdrawalRequest[] memory reqs = locked.getUserWithdrawalRequests(alice);
    assertEq(reqs.length, 1, "single queued payout, claim-only exit");
  }

  /* -------------------- B3: locked daily cap independent -------------------- */

  function test_B3_lockedDailyLimitIndependentFromFlex() public {
    vm.warp(T0);
    vm.startPrank(manager);
    flex.setDailyLimit(200_000 ether);
    locked.setDailyLimit(200_000 ether);
    locked.setPenaltyRate(0); // isolate daily-limit behavior from penalty math
    vm.stopPrank();
    _openCohort(1);

    // same day: flex fills its own 200k cap
    _depositFlex(alice, 200_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(200_000 ether);

    // same day: a 200k locked early-redeem must still pass on its own counter
    _depositLocked(alice, 1, 200_000 ether, false);
    vm.prank(alice);
    locked.requestEarlyRedeem(0, 200_000 ether);
    assertEq(locked.totalPendingWithdraw(), 200_000 ether, "locked daily counter is separate from flex");
  }

  /* ---------------------- B4: matured withdrawal ---------------------- */

  function test_B4_maturityWithdrawNoPenaltyExemptFromDailyCap() public {
    vm.warp(T0);
    vm.prank(manager);
    locked.setDailyLimit(200_000 ether); // cap well below the position size
    _openCohort(1);
    _depositLocked(alice, 1, 500_000 ether, false);

    vm.warp(block.timestamp + 92 days); // matured
    vm.prank(alice);
    locked.requestMaturityWithdraw(0); // 500k > 200k cap, but maturity is exempt

    assertEq(locked.totalPendingWithdraw(), 500_000 ether, "full principal queued, no penalty, no cap");
    LockedEarnPool.Position[] memory pos = locked.getUserPositions(alice);
    assertTrue(pos[0].closed);
  }

  function test_B4_maturityWithdrawBeforeMaturityReverts() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, false);

    vm.prank(alice);
    vm.expectRevert("not matured");
    locked.requestMaturityWithdraw(0);
  }

  function test_B4_maturityWithdrawWhileAutoRenewReverts() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, true); // auto-renew ON

    vm.warp(block.timestamp + 92 days);
    vm.prank(alice);
    vm.expectRevert("auto renew on");
    locked.requestMaturityWithdraw(0);
  }

  function test_B4_batchMaturityWithdrawIsBotOnly() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, false);
    vm.warp(block.timestamp + 92 days);

    address[] memory users = new address[](1);
    uint256[] memory posIds = new uint256[](1);
    users[0] = alice;
    posIds[0] = 0;

    vm.prank(manager); // manager lacks BOT
    vm.expectRevert();
    locked.batchRequestMaturityWithdraw(users, posIds);

    vm.prank(bot);
    locked.batchRequestMaturityWithdraw(users, posIds);
    assertEq(locked.totalPendingWithdraw(), 50_000 ether, "BOT queued the matured principal");
  }

  /* ------------------------- B5: auto-renew (renew) ------------------------- */

  function test_B5_renewRollsPrincipalOnlyForcesAutoRenewOff() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, true); // auto-renew ON
    vm.warp(block.timestamp + 92 days); // matured
    _openCohort(2); // fresh cohort to renew into

    uint256 adapterBefore = usdt.balanceOf(address(adapter));
    uint256 totalBefore = locked.totalPrincipalAmount();

    vm.prank(bot);
    locked.renewPosition(alice, 0, 2);

    LockedEarnPool.Position[] memory pos = locked.getUserPositions(alice);
    assertTrue(pos[0].closed, "old position closed");
    assertEq(pos[1].principal, 50_000 ether, "principal rolled into the new term");
    assertEq(pos[1].cohortId, 2);
    assertFalse(pos[1].autoRenew, "one-term cap: new position has auto-renew forced off");
    assertEq(locked.totalPrincipalAmount(), totalBefore, "principal moved, not created");
    assertEq(usdt.balanceOf(address(adapter)), adapterBefore, "renewal moves no funds");
  }

  function test_B5_renewNonBotReverts() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, true);
    vm.warp(block.timestamp + 92 days);
    _openCohort(2);

    vm.prank(alice);
    vm.expectRevert();
    locked.renewPosition(alice, 0, 2);
  }

  /* ------------------------- B6: toggle T-window lock ------------------------- */

  function test_B6_toggleAutoRenewOutsideLockWindow() public {
    vm.warp(T0);
    _openCohort(1); // maturity = now + 91 days, lock window 32 days
    _depositLocked(alice, 1, 50_000 ether, false);

    vm.prank(alice);
    locked.toggleAutoRenew(0); // now + 32d < maturity -> allowed
    LockedEarnPool.Position[] memory pos = locked.getUserPositions(alice);
    assertTrue(pos[0].autoRenew, "toggled on outside the lock window");
  }

  function test_B6_toggleAutoRenewLockedAtWindowBoundary() public {
    vm.warp(T0);
    uint256 maturity = block.timestamp + 91 days;
    _setCohort(1, 90, block.timestamp + 1 days, maturity, true);
    _depositLocked(alice, 1, 50_000 ether, false);

    // exactly T-32: block.timestamp + 32d == maturity, guard uses '<' so it reverts
    vm.warp(maturity - 32 days);
    vm.prank(alice);
    vm.expectRevert("auto renew locked (T-30)");
    locked.toggleAutoRenew(0);
  }

  /* --------------------------- B7: one-click reinvest --------------------------- */

  function test_B7_reinvestRollsFundedPayoutIntoNewCohort() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, false);
    vm.warp(block.timestamp + 92 days); // matured
    _openCohort(2); // reinvest target, deposit window open

    vm.prank(alice);
    locked.requestMaturityWithdraw(0);
    _fundAdapter(50_000 ether);
    vm.prank(bot);
    adapter.finishLockedWithdraw(50_000 ether); // batch confirmed

    uint256 adapterBefore = usdt.balanceOf(address(adapter));
    vm.prank(alice);
    locked.reinvest(0, 2);

    LockedEarnPool.Position[] memory pos = locked.getUserPositions(alice);
    assertEq(pos.length, 2, "new position appended");
    assertEq(pos[1].principal, 50_000 ether, "funded payout rolled as principal");
    assertEq(pos[1].cohortId, 2);
    assertFalse(pos[1].autoRenew, "one-term cap on reinvest too");
    assertEq(locked.totalPrincipalAmount(), 50_000 ether, "principal re-booked");
    assertEq(usdt.balanceOf(address(adapter)), adapterBefore + 50_000 ether, "funds return to adapter custody");
    assertEq(locked.totalPendingWithdraw(), 0, "confirmed request consumed");
  }

  function test_B7_reinvestBlockedByDepositPauseButClaimStaysOpen() public {
    vm.warp(T0);
    _openCohort(1);
    _depositLocked(alice, 1, 50_000 ether, false);
    vm.warp(block.timestamp + 92 days);
    _openCohort(2);

    vm.prank(alice);
    locked.requestMaturityWithdraw(0);
    _fundAdapter(50_000 ether);
    vm.prank(bot);
    adapter.finishLockedWithdraw(50_000 ether);

    // wind-down blocks reinvest (entry-side), but claim stays open as the escape hatch
    vm.prank(manager);
    locked.setDepositPaused(true);

    vm.prank(alice);
    vm.expectRevert("deposit paused");
    locked.reinvest(0, 2);

    vm.prank(alice);
    locked.claimWithdraw(alice, 0);
    assertEq(usdt.balanceOf(alice), 50_000 ether, "claim remains available during wind-down");
  }

  /* --------------------------- B8: setCohort guardrails --------------------------- */

  function test_B8_setCohortMaturityGuardrails() public {
    vm.warp(T0);
    uint256 dl = block.timestamp + 1 days;
    uint256 nominalEnd = dl + 90 days;

    _setCohort(1, 90, dl, nominalEnd, true); // maturity == nominal end: ok

    vm.prank(bot);
    vm.expectRevert("maturity before term end");
    locked.setCohort(2, 90, dl, nominalEnd - 1, true);

    vm.prank(bot);
    vm.expectRevert("maturity too late");
    locked.setCohort(3, 90, dl, nominalEnd + 31 days + 1, true); // beyond MAX_ALIGN_WINDOW

    vm.prank(bot);
    vm.expectRevert("term is zero");
    locked.setCohort(4, 0, dl, nominalEnd, true);
  }

  function test_B8_setCohortMaxAlignWindowBoundaryOk() public {
    vm.warp(T0);
    uint256 dl = block.timestamp + 1 days;
    uint256 nominalEnd = dl + 90 days;
    // exactly nominalEnd + 31 days (MAX_ALIGN_WINDOW) is accepted
    _setCohort(1, 90, dl, nominalEnd + 31 days, true);
    (, , uint256 maturityTime, bool enabled) = locked.cohorts(1);
    assertEq(maturityTime, nominalEnd + 31 days);
    assertTrue(enabled);
  }

  function test_B8_setCohortIsBotOnly() public {
    vm.warp(T0);
    vm.prank(manager); // manager no longer holds this power (moved to BOT)
    vm.expectRevert();
    locked.setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
  }

  /* --------------------------- deposit-side guards --------------------------- */

  function test_B_depositIntoDisabledCohortReverts() public {
    vm.warp(T0);
    _setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, false); // disabled

    usdt.mint(alice, 1_000 ether);
    vm.startPrank(alice);
    usdt.approve(address(locked), 1_000 ether);
    vm.expectRevert("cohort not enabled");
    locked.deposit(1, 1_000 ether, alice, false);
    vm.stopPrank();
  }

  function test_B_depositPastDeadlineReverts() public {
    vm.warp(T0);
    _openCohort(1);
    vm.warp(block.timestamp + 2 days); // past the deposit deadline

    usdt.mint(alice, 1_000 ether);
    vm.startPrank(alice);
    usdt.approve(address(locked), 1_000 ether);
    vm.expectRevert("deposit window closed");
    locked.deposit(1, 1_000 ether, alice, false);
    vm.stopPrank();
  }
}
