// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";
import "../../src/surfin/CreditFundBase.sol";

/**
 * Stateful handler driving random flex-pool + adapter lifecycles for the
 * invariant runner. Every action is guarded so it never reverts spuriously
 * (bounded amounts, skip when nothing to do), which keeps the fuzzed sequences
 * long and the invariants meaningful rather than vacuous.
 */
contract FlexInvariantHandler is Test {
  MockERC20 usdt;
  SurfinAdapter adapter;
  FlexEarnPool flex;
  address bot;
  address manager;
  address[] internal actors;

  constructor(MockERC20 _usdt, SurfinAdapter _adapter, FlexEarnPool _flex, address _bot, address _manager) {
    usdt = _usdt;
    adapter = _adapter;
    flex = _flex;
    bot = _bot;
    manager = _manager;
    actors.push(makeAddr("inv_actor_1"));
    actors.push(makeAddr("inv_actor_2"));
    actors.push(makeAddr("inv_actor_3"));
  }

  function depositFlex(uint256 actorSeed, uint256 amount) public {
    address a = actors[actorSeed % actors.length];
    amount = bound(amount, 1e18, 1_000_000e18);
    usdt.mint(a, amount);
    vm.startPrank(a);
    usdt.approve(address(flex), amount);
    flex.deposit(amount, a);
    vm.stopPrank();
  }

  function requestWithdraw(uint256 actorSeed, uint256 amount) public {
    address a = actors[actorSeed % actors.length];
    uint256 bal = flex.balanceOf(a);
    if (bal == 0) return;
    amount = bound(amount, 1, bal);
    vm.prank(a);
    flex.requestWithdraw(amount);
  }

  function finishFlex(uint256 amount) public {
    uint256 avail = adapter.instantWithdrawable();
    uint256 pend = flex.totalPendingWithdraw();
    uint256 quota = flex.withdrawQuota();
    uint256 room = pend > quota ? pend - quota : 0;
    uint256 max = avail < room ? avail : room;
    amount = max == 0 ? 0 : bound(amount, 0, max);
    vm.prank(bot);
    adapter.finishFlexWithdraw(amount);
  }

  function claimFlex(uint256 actorSeed) public {
    address a = actors[actorSeed % actors.length];
    CreditFundBase.WithdrawalRequest[] memory reqs = flex.getUserWithdrawalRequests(a);
    for (uint256 i = 0; i < reqs.length; i++) {
      if (reqs[i].batchId <= flex.confirmedBatchId()) {
        vm.prank(a);
        flex.claimWithdraw(a, i, reqs[i].amount);
        return;
      }
    }
  }

  function deploy(uint256 amount) public {
    uint256 max = adapter.maxDeployToSurfin();
    if (max == 0) return;
    amount = bound(amount, 1, max);
    vm.prank(manager);
    adapter.deployToSurfin(amount);
  }

  /// @dev emulate Surfin returning cash to the adapter (raw inflow), so the queue
  ///      can keep being funded without going through the full recall settlement.
  function recallCash(uint256 amount) public {
    amount = bound(amount, 0, 1_000_000e18);
    if (amount > 0) usdt.mint(address(adapter), amount);
  }

  /// @dev principal of confirmed-but-unclaimed requests across all actors.
  function confirmedUnclaimed() external view returns (uint256 sum) {
    uint256 confirmed = flex.confirmedBatchId();
    for (uint256 j = 0; j < actors.length; j++) {
      CreditFundBase.WithdrawalRequest[] memory reqs = flex.getUserWithdrawalRequests(actors[j]);
      for (uint256 i = 0; i < reqs.length; i++) {
        if (reqs[i].batchId <= confirmed) sum += reqs[i].amount;
      }
    }
  }
}

/**
 * Test group 1 — core invariants (highest priority). These are the "must always
 * hold" safety properties the PRD implies (§4.5–§4.7, §14.4). The stateful runner
 * fuzzes random flex lifecycles; the deterministic tests pin the exact PRD-derived
 * properties for INV-2/3/4.
 */
contract SurfinInvariant is SurfinTestBase {
  FlexInvariantHandler handler;

  function setUp() public override {
    super.setUp();
    handler = new FlexInvariantHandler(usdt, adapter, flex, bot, manager);
    targetContract(address(handler));
  }

  /* ---- INV-1: pool solvency (a confirmed batch is always fully backed by cash) ---- */
  /// @dev provable identity: poolBalance == withdrawQuota + confirmedUnclaimed, hence
  ///      the pool can always pay every user whose batch is already confirmed.
  function invariant_flexPoolSolvent() public view {
    assertGe(usdt.balanceOf(address(flex)), handler.confirmedUnclaimed(), "flex pool cannot cover confirmed claims");
  }

  /* ---- INV-3: the adapter never over-pushes past the pool's real obligation ---- */
  /// @dev A global invariant once the bound is the UNCONFIRMED obligation rather than
  ///      totalPendingWithdraw. The wider bound counts confirmed-but-unclaimed payouts
  ///      whose cash already sits in the pool, so a partial fund followed by a
  ///      cancellation could strand surplus quota behind that mask until the last claim
  ///      exposed it. Cancellation now returns the orphan on the spot, so the property
  ///      survives every action the handler can take.
  ///
  ///      Caveat: adminTopUp deliberately bypasses the cap to cover a shortfall on
  ///      an impaired fund, so it can leave quota above this bound by design. The handler
  ///      does not drive it; if it is ever added, exclude it here.
  function invariant_quotaNeverExceedsUnconfirmedObligation() public view {
    assertLe(
      flex.withdrawQuota(),
      flex.totalPendingWithdraw() - flex.totalConfirmedUnclaimed(),
      "quota exceeds the obligation still awaiting adapter cash"
    );
  }

  /// @dev the on-chain counter must always equal the payouts actually sitting confirmed in
  ///      the queue — pins the += in _confirmBatches against the -= in
  ///      _consumeConfirmedWithdraw, the pair the guard above depends on.
  function invariant_confirmedUnclaimedMatchesQueue() public view {
    assertEq(
      flex.totalConfirmedUnclaimed(),
      handler.confirmedUnclaimed(),
      "totalConfirmedUnclaimed drifted from the queue"
    );
  }

  /* ---- INV-2: the on-chain hard floor is never paid out by withdrawal flows ---- */
  function invariant_floorNeverBreached() public view {
    assertGe(adapter.idleBalance(), adapter.hardFloor(), "hard floor breached");
  }

  /* =========================== deterministic INV pins =========================== */

  /**
   * INV-1 (fund conservation, PRD §14 asset/liability reconciliation): across a full
   * lifecycle no USDT is created or lost. With fee = 0 and the deployed book matching
   * the physical Surfin holding, the perimeter identity holds at every step:
   *   adapterIdle + flexBalance + surfinWalletBalance == principal + pending
   */
  function test_inv1_fundConservationAcrossLifecycle() public {
    _depositFlex(alice, 100_000 ether); // idle 100k, principal 100k
    _assertConservation();

    vm.prank(alice);
    flex.requestWithdraw(50_000 ether); // principal 50k, pending 50k
    _assertConservation();

    // available = idle(100k) - hardFloor(3% * 100k = 3k) = 97k >= 50k: batch fully funded
    vm.prank(bot);
    adapter.finishFlexWithdraw(50_000 ether); // idle 50k, flex 50k, batch confirmed
    _assertConservation();

    vm.prank(alice);
    flex.claimWithdraw(alice, 0, 50_000 ether); // alice +50k, flex 0, pending 0
    _assertConservation();

    // remaining idle can be deployed down to the (now smaller) floor
    uint256 max = adapter.maxDeployToSurfin(); // freeIdle(50k) - 3% * 50k = 48.5k
    vm.prank(manager);
    adapter.deployToSurfin(max); // idle 1.5k, surfin 48.5k
    _assertConservation();
  }

  /**
   * INV-2 (hard floor protection, PRD §4.5/§4.7/§14.4) plus its single exception:
   * withdrawal flows can never pierce the floor, but interest funding (§4.2, floor
   * doubles as the interest reserve) is allowed to.
   */
  function test_inv2_floorProtectedFromWithdraw_butInterestMayPierce() public {
    _depositFlex(alice, 100_000 ether); // idle 100k, hardFloor 3k, available 97k

    // withdrawal flow cannot cross the floor
    vm.prank(bot);
    vm.expectRevert("exceeds available");
    adapter.finishFlexWithdraw(97_001 ether);

    // interest funding is the one path allowed to consume the floor
    vm.prank(manager);
    adapter.fundInterest(100_000 ether); // eats through the 3k floor
    assertEq(adapter.idleBalance(), 0, "interest may drain down to zero");
    assertLt(adapter.idleBalance(), adapter.hardFloor(), "floor pierced only via interest");
  }

  /**
   * INV-3 (adapter cannot over-fund, PRD §4.6 net settlement): pushing more than the
   * pool's pending obligation reverts even when the adapter holds the cash.
   */
  function test_inv3_finishRevertsWhenQuotaExceedsPending() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(40_000 ether); // pending 40k

    // 90k <= available(97k) clears the reserve guard, but exceeds the 40k pending
    vm.prank(bot);
    vm.expectRevert("quota exceeds pending");
    adapter.finishFlexWithdraw(90_000 ether);
  }

  /**
   * INV-4 (floor base restoration, PRD §14.4 conservative sizing): requesting a
   * withdrawal burns LP but the funds have not left yet, so totalPendingWithdraw
   * must backfill the floor base — the hard floor does not drop.
   */
  function test_inv4_floorBaseRestoredAfterRequest() public {
    _depositFlex(alice, 100_000 ether);
    uint256 floorBefore = adapter.hardFloor();

    vm.prank(alice);
    flex.requestWithdraw(50_000 ether);
    uint256 floorAfter = adapter.hardFloor();

    assertEq(floorAfter, floorBefore, "hard floor must not drop when request only burns LP");
    assertEq(floorAfter, 3_000 ether, "3% of the 100k book is preserved");
  }

  /**
   * INV-5: the mirror of INV-4. A pending withdrawal backfills
   * the floor base only while its cash is still in the adapter. Once finishWithdraw
   * pushes that cash into the pool the liability must leave the base, or the adapter
   * reserves twice over — against liquidity it no longer holds.
   */
  function test_inv5_fundedWithdrawLeavesFloorBase() public {
    _depositFlex(alice, 100_000 ether);
    _depositFlex(bob, 100_000 ether);
    assertEq(adapter.hardFloor(), 6_000 ether, "3% of the 200k book");

    vm.prank(bob);
    flex.requestWithdraw(100_000 ether);
    // INV-4 half: cash has not moved yet, so the base is unchanged
    assertEq(adapter.hardFloor(), 6_000 ether, "base restored while the cash is still here");

    vm.prank(bot);
    adapter.finishFlexWithdraw(100_000 ether); // confirmed; 100k now sits in the pool
    assertEq(flex.totalPendingWithdraw(), 100_000 ether, "pending clears only on claim");
    assertEq(flex.totalConfirmedUnclaimed(), 100_000 ether, "funded and awaiting bob's claim");

    // only alice's 100k is still backed by adapter cash -> 3% of 100k, not 200k
    assertEq(adapter.hardFloor(), 3_000 ether, "funded-but-unclaimed no longer inflates the floor");

    // and it stays there once bob finally claims: nothing double-counted on the way out
    vm.prank(bob);
    flex.claimWithdraw(bob, 0, 100_000 ether);
    assertEq(adapter.hardFloor(), 3_000 ether, "claim does not move the floor again");
  }

  /**
   * INV-6: a partially funded batch must not wedge itself. The
   * old base counted the whole pending batch while the part-funding drained the very
   * balance needed to clear it, so available liquidity hit zero with the batch still
   * unconfirmed — and FIFO stalled every batch behind it.
   */
  function test_inv6_partiallyFundedBatchCanStillBeCompleted() public {
    _depositFlex(alice, 100 ether);
    vm.prank(alice);
    flex.requestWithdraw(98 ether); // 2 live principal, 98 pending, floor 3% of 100 = 3

    assertEq(adapter.hardFloor(), 3 ether, "full batch still backed by adapter cash");
    assertEq(adapter.instantWithdrawable(), 97 ether, "one ether short of the 98 batch");

    vm.prank(bot);
    adapter.finishFlexWithdraw(97 ether); // partial: batch needs 98, stays unconfirmed
    assertEq(flex.confirmedBatchId(), 0, "batch not confirmed on partial funding");
    assertEq(flex.withdrawQuota(), 97 ether, "97 parked in the pool as quota");

    // base is now 2 live + the 1 still owed = 3; the 97 already in the pool is not
    // the adapter's to reserve against, so the remaining ether is payable
    assertEq(adapter.hardFloor(), 0.09 ether, "floor tracks only adapter-held liability");
    assertGe(adapter.instantWithdrawable(), 1 ether, "top-up is not blocked by a stale floor");

    vm.prank(bot);
    adapter.finishFlexWithdraw(1 ether);
    assertEq(flex.confirmedBatchId(), 1, "batch confirmed on top-up");

    vm.prank(alice);
    flex.claimWithdraw(alice, 0, 98 ether);
    assertEq(usdt.balanceOf(alice), 98 ether, "user exits in full");
  }

  /**
   * INV-7: a queued withdrawal must stay fundable. Requesting an
   * exit only moves accounting from principal into totalPendingWithdraw, so the deploy
   * ceiling used to ignore it entirely and the manager could send off the very cash
   * meant to pay it.
   */
  function test_inv7_deployCeilingReservesQueuedWithdrawals() public {
    _depositFlex(alice, 100_000 ether);
    assertEq(adapter.maxDeployToSurfin(), 97_000 ether, "no queue yet: idle - floor");

    vm.prank(alice);
    flex.requestWithdraw(50_000 ether);

    // floor base is unchanged (cash still here) -> 3k; the 50k queue is now reserved too
    assertEq(adapter.unfundedWithdrawals(), 50_000 ether, "queue owed cash");
    assertEq(adapter.maxDeployToSurfin(), 47_000 ether, "100k - 3k floor - 50k queue");

    // deploying the whole ceiling must still leave the queue payable
    vm.prank(manager);
    adapter.deployToSurfin(47_000 ether);
    assertGe(adapter.instantWithdrawable(), 50_000 ether, "queue still fundable after max deploy");

    vm.prank(bot);
    adapter.finishFlexWithdraw(50_000 ether);
    vm.prank(alice);
    flex.claimWithdraw(alice, 0, 50_000 ether);
    assertEq(usdt.balanceOf(alice), 50_000 ether, "user exits without waiting for a recall");
  }

  /// @dev once a queue is funded it stops being reserved — the cash left the adapter.
  function test_inv7_fundedQueueStopsReservingDeployCapacity() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(50_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(50_000 ether); // confirmed, cash now in the pool

    assertEq(adapter.unfundedWithdrawals(), 0, "nothing left owed");
    // idle 50k, floor base = 50k principal only -> 1.5k
    assertEq(adapter.maxDeployToSurfin(), 48_500 ether, "50k - 1.5k floor");
  }

  /**
   * INV-8: interest may consume the hard floor, but never the
   * cash a queued withdrawal is already waiting on — otherwise a fresh deposit gets
   * paid out as someone else's interest and the principal liability goes unbacked.
   */
  function test_inv8_interestCannotConsumeQueuedWithdrawalCash() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(alice);
    flex.requestWithdraw(60_000 ether);

    // free idle 100k, of which 60k is spoken for -> 40k fundable as interest
    assertEq(adapter.freeIdle(), 100_000 ether);
    vm.prank(manager);
    vm.expectRevert("insufficient idle");
    adapter.fundInterest(40_000 ether + 1);

    vm.prank(manager);
    adapter.fundInterest(40_000 ether);
    assertEq(usdt.balanceOf(address(distributor)), 40_000 ether);
    assertEq(adapter.idleBalance(), 60_000 ether, "the queue's cash stayed home");

    // The residual is the hard floor itself: withdrawals may never pierce it, so a
    // maxed-out interest run leaves the queue payable down to the floor (60k - 3k) and
    // the last slice waits for the next recall. Under the old freeIdle cap the whole
    // 100k could have gone out and the queue would have been left with nothing.
    assertEq(adapter.hardFloor(), 3_000 ether);
    assertEq(adapter.instantWithdrawable(), 57_000 ether, "payable down to the floor");
    vm.prank(bot);
    adapter.finishFlexWithdraw(57_000 ether);
    assertEq(flex.confirmedBatchId(), 0, "60k batch still 3k short");

    // recall tops the floor back up; the batch then confirms and alice exits in full
    _fundAdapter(3_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(3_000 ether);
    vm.prank(alice);
    flex.claimWithdraw(alice, 0, 60_000 ether);
    assertEq(usdt.balanceOf(alice), 60_000 ether, "queued exit survived the interest run");
  }

  /// inv9 — a locked MATURITY queue blocks neither interest funding nor deployment,
  ///        while a flex queue still reserves against both. The maturity queue is settled
  ///        from the recall proceeds earmarked for it, so reserving it out of idle cash
  ///        reserves the same obligation twice; the old rule froze interest for every
  ///        user (flex holders included) and froze deployment for the whole
  ///        maturity-to-recall gap, and no in-pool action could clear it — feeding the
  ///        queue lowers idle and the reservation by the same amount.
  function test_inv9_lockedMaturityQueueBlocksNeitherInterestNorDeploy() public {
    vm.warp(1_000_000);
    _setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    _depositLocked(alice, 1, 500_000 ether, false);
    _depositFlex(bob, 100_000 ether);

    // the locked principal is put to work at Surfin, leaving only the 100k buffer idle
    vm.prank(manager);
    adapter.deployToSurfin(500_000 ether);
    assertEq(adapter.idleBalance(), 100_000 ether, "only the buffer stays home");

    // the cohort matures and the BOT queues the exit; the recall has not landed yet
    vm.warp(block.timestamp + 92 days);
    address[] memory users = new address[](1);
    uint256[] memory posIds = new uint256[](1);
    users[0] = alice;
    vm.prank(bot);
    locked.batchRequestMaturityWithdraw(users, posIds);

    assertEq(locked.totalPendingWithdraw(), 500_000 ether, "maturity queued");
    assertEq(adapter.unfundedWithdrawals(), 500_000 ether, "the full obligation is still reported");
    assertEq(adapter.onDemandUnfunded(), 0, "but none of it is payable on demand");

    // deployment is no longer frozen: idle 100k - 18k floor (floor base is unchanged,
    // the maturing principal just moved from totalPrincipal into the pending queue)
    assertEq(adapter.hardFloor(), 18_000 ether);
    assertEq(adapter.maxDeployToSurfin(), 82_000 ether, "maturity queue no longer freezes deploy");

    // interest for the epoch is fundable out of the idle buffer
    assertEq(adapter.freeIdle(), 100_000 ether);
    vm.prank(manager);
    adapter.fundInterest(20_000 ether);
    assertEq(usdt.balanceOf(address(distributor)), 20_000 ether, "interest funded despite maturity queue");

    // a FLEX queue is still reserved: it is payable on demand from this same buffer
    vm.prank(bob);
    flex.requestWithdraw(60_000 ether);
    assertEq(adapter.onDemandUnfunded(), 60_000 ether, "flex queue reserved");
    assertEq(adapter.freeIdle(), 80_000 ether);
    vm.prank(manager);
    vm.expectRevert("insufficient idle");
    adapter.fundInterest(20_000 ether + 1);
    vm.prank(manager);
    adapter.fundInterest(20_000 ether); // 80k idle - 60k flex queue

    // the flex queue reserves against the deploy ceiling too: 60k idle left, of which the
    // 60k queue and the 18k floor claim everything, so nothing may leave for Surfin
    assertEq(adapter.idleBalance(), 60_000 ether);
    assertEq(adapter.maxDeployToSurfin(), 0, "flex queue + floor fully reserve the buffer");
    vm.prank(manager);
    vm.expectRevert("exceeds deployable");
    adapter.deployToSurfin(1);

    // and the queue is payable down to the floor, the documented residual: the last
    // slice waits for the next recall exactly as it did before this change
    assertEq(adapter.instantWithdrawable(), 42_000 ether, "60k idle - 18k floor");
    vm.prank(bot);
    adapter.finishFlexWithdraw(42_000 ether);
    assertEq(flex.confirmedBatchId(), 0, "60k batch still short by the floor");
  }

  /* ---- helper ---- */
  function _assertConservation() internal view {
    uint256 lhs = usdt.balanceOf(address(adapter)) + usdt.balanceOf(address(flex)) + usdt.balanceOf(surfinWallet);
    uint256 rhs = flex.totalPrincipal() + flex.totalPendingWithdraw();
    assertEq(lhs, rhs, "USDT conservation broken");
  }
}
