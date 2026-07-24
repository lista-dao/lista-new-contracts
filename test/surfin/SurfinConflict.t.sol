// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";

/**
 * Test group 2 — PRD vs contract conflict points (highest-value review targets).
 *
 * These tests assert the CURRENT on-chain behavior on purpose, so the suite stays
 * green, while documenting where it diverges from the PRD. Each one is a concrete
 * "PRD expects X, contract does Y" artifact to take to product/contract owners. If a
 * divergence is confirmed a real gap, flip the assertion after the fix lands.
 */
contract SurfinConflict is SurfinTestBase {
  /* ============================================================================
   * CONFLICT-1 — claim-type operations are pause-gated.
   *
   * PRD §4.9: claim-type actions are NOT subject to pause; already-funded money must
   *           stay claimable even in the Frozen state ("users always have an exit").
   * CONTRACT: CreditFundBase.claimWithdraw and InterestDistributor.claim both carry
   *           whenNotPaused, so pausing blocks users from claiming funds that were
   *           already pushed to them.
   * ==========================================================================*/

  /// @dev A confirmed, fully-funded flex withdrawal becomes unclaimable once paused.
  ///      PRD §4.9 expects this claim to succeed.
  function test_conflict1_flexClaimBlockedByPause_divergesFromPRD() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(50_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(50_000 ether); // batch confirmed, 50k cash sits in the pool

    vm.prank(pauser);
    flex.pause();

    // PRD §4.9 expectation: alice can still claim her already-funded 50k.
    // CURRENT behavior: whenNotPaused reverts the claim.
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
    flex.claimWithdraw(alice, 0);
  }

  /// @dev The same divergence for interest: a valid, funded Merkle claim is blocked
  ///      while the distributor is paused. PRD §4.9 expects interest claims to remain open.
  function test_conflict1_interestClaimBlockedByPause_divergesFromPRD() public {
    _depositFlex(alice, 100_000 ether); // gives the adapter idle cash to fund interest

    vm.prank(manager);
    adapter.fundInterest(1_000 ether); // move 1k into the distributor

    bytes32 root = _leaf(alice, 1_000 ether);
    _publishRoot(root);

    vm.prank(pauser);
    distributor.pause();

    bytes32[] memory proof = new bytes32[](0);
    // PRD §4.9 expectation: alice claims her 1k interest. CURRENT: whenNotPaused reverts.
    vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
    distributor.claim(alice, 1_000 ether, proof);
  }

  /// @dev Counter-check: depositPaused (wind-down) intentionally does NOT block claims
  ///      (only entry-side ops), which matches PRD §4.9's "always an exit". This is the
  ///      behavior the pause() gate above should arguably mirror.
  function test_conflict1_depositPausedKeepsClaimOpen_matchesPRD() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(50_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(50_000 ether);

    vm.prank(manager);
    flex.setDepositPaused(true); // wind-down: blocks deposits, not claims

    vm.prank(alice);
    flex.claimWithdraw(alice, 0); // succeeds
    assertEq(usdt.balanceOf(alice), 50_000 ether, "claim stays open during wind-down");
  }

  /* ============================================================================
   * CONFLICT-2 — early-redeem penalty is locked in and never reversed at maturity.
   *
   * PRD §4.4: if an early-redeem request is left unfunded until the position's own
   *           maturity (T-30 checkpoint), the penalty is VOIDED — the request converts
   *           to a normal maturity withdrawal (full principal) and base interest is
   *           back-filled for the whole term.
   * CONTRACT: requestEarlyRedeem computes the penalized payout once, at request time,
   *           and enqueues it. There is no maturity-reversal path, so the penalty
   *           stands no matter how long funding takes.
   * ==========================================================================*/

  function test_conflict2_earlyRedeemPenaltyStandsPastMaturity_divergesFromPRD() public {
    vm.warp(1_000_000);
    // cohort 1: 90-day term, deposits close at +1 day, maturity at +91 days
    _setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    _depositLocked(alice, 1, 50_000 ether, false);

    // early redeem the full position within the 30-day penalty window (0.8% default)
    uint256 payout = locked.previewEarlyRedeem(alice, 0, 50_000 ether);
    assertEq(payout, 49_600 ether, "0.8% penalty applied inside the window");
    vm.prank(alice);
    locked.requestEarlyRedeem(0, 50_000 ether); // enqueues 49,600; position closed

    // the request sits unfunded until well past the position's maturity
    vm.warp(block.timestamp + 100 days);

    // fund and confirm the queued redemption
    _fundAdapter(50_000 ether);
    vm.prank(bot);
    adapter.finishLockedWithdraw(49_600 ether);
    vm.prank(alice);
    locked.claimWithdraw(alice, 0);

    // CURRENT: alice receives the penalized 49,600 even though the wait ran past
    // maturity. PRD §4.4 expects 50,000 (penalty voided) + full-term base interest.
    assertEq(usdt.balanceOf(alice), 49_600 ether, "penalty stands past maturity (diverges from PRD 4.4)");
    assertLt(usdt.balanceOf(alice), 50_000 ether, "principal was reduced by a penalty that PRD would have voided");
  }
}
