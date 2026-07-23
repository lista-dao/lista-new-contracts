// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";

/**
 * Test group 4 — end-to-end user journeys (closest to the PRD §11 personas).
 *
 * Each journey walks a persona across contract boundaries (pool -> adapter ->
 * distributor) to prove the pieces connect, not just that each unit works:
 *  - Alice: flex full cycle, principal via the batch queue, interest via the distributor
 *  - Bob:   locked auto-renew, capped at exactly one term
 *  - Charlie: early redeem takes a principal haircut end-to-end
 *  - Eve:   matured principal exits via BOT batching + weekly settleRecall, cap-exempt
 *  - Frank: an oversized withdrawal is forced to split across UTC days by the cap
 */
contract SurfinJourneyTest is SurfinTestBase {
  address eve = makeAddr("eve");
  address frank = makeAddr("frank");

  /* ------------------------------- Alice ------------------------------- */

  function test_journey_Alice_flexFullCycle() public {
    // 1. deposit — funds custody at the adapter
    _depositFlex(alice, 10_000 ether);
    assertEq(usdt.balanceOf(address(adapter)), 10_000 ether);

    // 2. manager deploys the deployable surplus to Surfin
    uint256 deployable = adapter.maxDeployToSurfin(); // 10k - 300 floor = 9,700
    vm.prank(manager);
    adapter.deployToSurfin(deployable);

    // 3. alice requests her full principal back
    vm.prank(alice);
    flex.requestWithdraw(10_000 ether);

    // 4. Surfin returns cash; BOT funds the batch
    _fundAdapter(10_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(10_000 ether);

    // 5. claim principal to the wallet
    vm.prank(alice);
    flex.claimWithdraw(alice, 0);
    assertEq(usdt.balanceOf(alice), 10_000 ether, "principal fully returned via the queue");

    // 6. interest is separate: funded to, and claimed from, the distributor
    _fundAdapter(100 ether);
    vm.prank(manager);
    adapter.fundInterest(100 ether);
    _publishRoot(_leaf(alice, 100 ether));
    bytes32[] memory empty = new bytes32[](0);
    distributor.claim(alice, 100 ether, empty);

    assertEq(usdt.balanceOf(alice), 10_100 ether, "principal + interest, interest via the distributor");
  }

  /* -------------------------------- Bob -------------------------------- */

  function test_journey_Bob_lockedRenewCappedAtOneTerm() public {
    vm.warp(1_000_000);
    _setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    _depositLocked(bob, 1, 50_000 ether, true); // auto-renew ON

    // term 1 matures -> BOT renews into term 2 (auto-renew forced off)
    vm.warp(block.timestamp + 92 days);
    _setCohort(2, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    vm.prank(bot);
    locked.renewPosition(bob, 0, 2);

    // term 2 matures -> a second renewal is refused (one-term cap)
    vm.warp(block.timestamp + 92 days);
    _setCohort(3, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    vm.prank(bot);
    vm.expectRevert("auto renew off");
    locked.renewPosition(bob, 1, 3);

    // instead the principal exits via a normal matured withdrawal
    vm.prank(bob);
    locked.requestMaturityWithdraw(1);
    assertEq(locked.totalPendingWithdraw(), 50_000 ether, "principal exits after exactly one renewal");
  }

  /* ------------------------------ Charlie ------------------------------ */

  function test_journey_Charlie_earlyRedeemPrincipalHaircut() public {
    vm.warp(1_000_000);
    _setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    _depositLocked(charlie, 1, 50_000 ether, false);

    vm.warp(block.timestamp + 15 days); // inside the penalty window
    vm.prank(charlie);
    locked.requestEarlyRedeem(0, 50_000 ether); // payout 49,600

    _fundAdapter(50_000 ether);
    vm.prank(bot);
    adapter.finishLockedWithdraw(49_600 ether);
    vm.prank(charlie);
    locked.claimWithdraw(charlie, 0);

    assertEq(usdt.balanceOf(charlie), 49_600 ether, "principal minus the 0.8% early-redeem penalty");
  }

  /* -------------------------------- Eve -------------------------------- */

  function test_journey_Eve_maturityViaSettleRecall() public {
    vm.warp(1_000_000);
    vm.prank(manager);
    locked.setDailyLimit(200_000 ether); // matured withdrawal must ignore this cap
    _setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    _depositLocked(eve, 1, 300_000 ether, false); // larger than the daily cap

    vm.warp(block.timestamp + 92 days);

    // BOT queues eve's matured principal on her behalf (settlement-day job)
    address[] memory users = new address[](1);
    uint256[] memory posIds = new uint256[](1);
    users[0] = eve;
    posIds[0] = 0;
    vm.prank(bot);
    locked.batchRequestMaturityWithdraw(users, posIds);
    assertEq(locked.totalPendingWithdraw(), 300_000 ether, "full principal queued despite the 200k cap");

    // the weekly recall settlement covers the locked queue out of the settlement funds
    _settleRecall(300_000 ether, 300_000 ether, 0, 0);
    assertEq(locked.confirmedBatchId(), 1, "settlement funds confirmed the matured batch");

    vm.prank(eve);
    locked.claimWithdraw(eve, 0);
    assertEq(usdt.balanceOf(eve), 300_000 ether, "full principal, no penalty, cap-exempt");
  }

  /* ------------------------------- Frank ------------------------------- */

  function test_journey_Frank_largeWithdrawSplitAcrossDays() public {
    vm.prank(manager);
    flex.setDailyLimit(200_000 ether);
    _depositFlex(frank, 800_000 ether);

    // day 1: 200k clears, anything more the same day reverts
    vm.prank(frank);
    flex.requestWithdraw(200_000 ether);
    vm.prank(frank);
    vm.expectRevert("exceeds daily limit");
    flex.requestWithdraw(1);

    // the remaining 600k has to spread across the next three UTC days
    for (uint256 i = 0; i < 3; i++) {
      vm.warp(block.timestamp + 1 days);
      vm.prank(frank);
      flex.requestWithdraw(200_000 ether);
    }

    assertEq(flex.balanceOf(frank), 0, "all 800k queued over four days");
    assertEq(flex.totalPendingWithdraw(), 800_000 ether);
  }
}
