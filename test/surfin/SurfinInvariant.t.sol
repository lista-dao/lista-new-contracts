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
        flex.claimWithdraw(a, i);
        return;
      }
    }
  }

  function cancelFlex(uint256 actorSeed) public {
    address a = actors[actorSeed % actors.length];
    CreditFundBase.WithdrawalRequest[] memory reqs = flex.getUserWithdrawalRequests(a);
    for (uint256 i = 0; i < reqs.length; i++) {
      if (reqs[i].batchId > flex.confirmedBatchId()) {
        vm.prank(a);
        flex.cancelWithdraw(i);
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
  /// @dev NOTE: `withdrawQuota <= totalPendingWithdraw` is deliberately NOT a global
  ///      invariant. It is enforced only on funding pushes (finishWithdraw with
  ///      amount > 0). A partially-funded batch that is then cancelled can strand
  ///      surplus quota (quota > pending) until a later batch or a 0-amount tick
  ///      consumes it — see finishWithdraw's comment and the existing
  ///      SurfinAdapterGuard cancel-after-partial-fund regression. The always-true
  ///      safety property is pool solvency (invariant_flexPoolSolvent above); the
  ///      per-push guard is pinned by test_inv3_finishRevertsWhenQuotaExceedsPending.

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
    flex.claimWithdraw(alice, 0); // alice +50k, flex 0, pending 0
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

  /* ---- helper ---- */
  function _assertConservation() internal view {
    uint256 lhs = usdt.balanceOf(address(adapter)) + usdt.balanceOf(address(flex)) + usdt.balanceOf(surfinWallet);
    uint256 rhs = flex.totalPrincipal() + flex.totalPendingWithdraw();
    assertEq(lhs, rhs, "USDT conservation broken");
  }
}
