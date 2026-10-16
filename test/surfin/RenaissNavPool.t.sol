// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";
import "../../src/surfin/RenaissNavPool.sol";

/**
 * Renaiss Card Vault on the Surfin template: perpetual NAV pool in the adapter's LOCKED
 * slot, flexPool = address(0), floorRate 0, USDT only, cap US$3M, min US$100.
 *
 * PRD worked examples (pool NAV $1,000,000, 1,000,000 shares, NAV $1.00):
 *  - Alice subscribes 10,000 -> 10,000 shares; NAV stays 1.00 (dilution, not repricing)
 *  - NAV +4% -> Alice's position is worth 10,400
 *  - Charlie: 50,000 shares requested at NAV 1.08, settled at 1.12 -> 56,000
 *  - Dave: requested at 1.08, settled at 0.97 -> 48,500 (forward pricing both ways)
 *  - Frank: cancels inside the window, shares return; cannot cancel once closed
 */
contract RenaissNavPoolTest is SurfinTestBase {
  RenaissNavPool pool;

  address dave = makeAddr("dave");
  address frank = makeAddr("frank");
  address market = makeAddr("market");

  uint256 constant NAV1 = 1e18;
  uint256 constant CAP = 3_000_000 ether;
  uint256 constant MIN_DEPOSIT = 100 ether;

  function setUp() public override {
    super.setUp();
    vm.warp(1_700_000_000);

    RenaissNavPool impl = new RenaissNavPool();
    pool = RenaissNavPool(
      address(
        new ERC1967Proxy(
          address(impl),
          abi.encodeWithSelector(
            impl.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(usdt),
            address(this),
            "Renaiss LP",
            "rLP",
            NAV1
          )
        )
      )
    );
    adapter = SurfinAdapter(
      address(
        new ERC1967Proxy(
          address(new SurfinAdapter(address(usdt))),
          abi.encodeWithSelector(
            SurfinAdapter.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(0), // no flex product
            address(pool), // the NAV pool rides the locked slot
            surfinWallet
          )
        )
      )
    );
    vm.prank(admin);
    pool.setAdapter(address(adapter));

    vm.startPrank(manager);
    adapter.setFloorRate(0);
    adapter.setFeeReceiver(feeReceiver);
    pool.setCap(CAP);
    pool.setMinDeposit(MIN_DEPOSIT);
    pool.setFeeReceiver(feeReceiver);
    vm.stopPrank();
  }

  /* ---------------------------------- helpers ---------------------------------- */

  function _subscribe(address who, uint256 amount) internal returns (uint256 shares) {
    usdt.mint(who, amount);
    vm.startPrank(who);
    usdt.approve(address(pool), amount);
    uint256 before = pool.balanceOf(who);
    pool.deposit(amount, who);
    vm.stopPrank();
    shares = pool.balanceOf(who) - before;
  }

  /// @dev the PRD baseline: 1,000,000 shares at NAV 1.00, all deployed to Renaiss.
  function _seedPool() internal {
    _subscribe(bob, 1_000_000 ether);
    vm.prank(manager);
    adapter.deployToSurfin(1_000_000 ether);
    assertEq(pool.totalSupply(), 1_000_000 ether);
    assertEq(pool.poolNav(), 1_000_000 ether);
  }

  function _publish(uint256 nav_) internal {
    vm.warp(block.timestamp + 7 days);
    vm.prank(manager);
    pool.publishNav(nav_);
  }

  function _request(address who, uint256 shares) internal returns (uint256 id) {
    vm.prank(who);
    id = pool.requestRedeem(shares);
  }

  function _ids(uint256 a) internal pure returns (uint256[] memory r) {
    r = new uint256[](1);
    r[0] = a;
  }

  /// @dev close, publish the settlement NAV, settle, and fund the whole payout.
  function _closeSettleAndFund(uint256 settlementNav) internal returns (uint256 payout) {
    vm.prank(manager);
    pool.closeCycle();
    _publish(settlementNav);
    vm.prank(manager);
    pool.settleCycle();
    (, , , , , , payout, , ) = pool.cycles(pool.currentCycleId());
    _settleRecall(payout, payout, 0, 0);
    assertEq(pool.confirmedBatchId(), pool.currentBatchId(), "cycle funded");
  }

  /* ------------------------------ PRD worked examples ------------------------------ */

  function test_example_aliceSubscriptionDilutesSharesNotNav() public {
    _seedPool();
    uint256 shares = _subscribe(alice, 10_000 ether);
    assertEq(shares, 10_000 ether, "1:1 at NAV 1.00");
    assertEq(pool.totalSupply(), 1_010_000 ether);
    assertEq(pool.poolNav(), 1_010_000 ether);
    assertEq(pool.nav(), NAV1, "subscription never moves the NAV");
    assertEq(usdt.balanceOf(address(adapter)), 10_000 ether, "funds land on the adapter");
  }

  function test_example_navGrowthIsTheReturn() public {
    _seedPool();
    _subscribe(alice, 10_000 ether);
    _publish(1.04e18);
    assertEq((pool.balanceOf(alice) * pool.nav()) / 1e18, 10_400 ether);
    assertEq(pool.balanceOf(alice), 10_000 ether, "no cash, no new shares");
  }

  function test_example_charlieForwardPricedUp() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(charlie, 50_000 ether);
    _publish(1.08e18);

    vm.prank(manager);
    pool.openCycle();
    uint256 id = _request(charlie, 50_000 ether);
    assertEq(pool.balanceOf(charlie), 0, "shares escrowed");
    assertEq(pool.balanceOf(address(pool)), 50_000 ether);

    uint256 payout = _closeSettleAndFund(1.12e18);
    assertEq(payout, 56_000 ether, "50,000 x 1.12");
    assertEq(pool.totalSupply(), 950_000 ether, "escrowed shares burned at settlement");

    vm.prank(charlie);
    pool.claimRedeem(charlie, _ids(id));
    assertEq(usdt.balanceOf(charlie), 56_000 ether);
    assertEq(pool.totalPendingWithdraw(), 0);
    assertEq(pool.totalConfirmedUnclaimed(), 0);
    assertEq(usdt.balanceOf(address(pool)), 0, "pool fully paid out");
  }

  function test_example_daveForwardPricedDown() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(dave, 50_000 ether);
    _publish(1.08e18);
    vm.prank(manager);
    pool.openCycle();
    uint256 id = _request(dave, 50_000 ether);

    uint256 payout = _closeSettleAndFund(0.97e18);
    assertEq(payout, 48_500 ether, "50,000 x 0.97");
    vm.prank(bot);
    pool.claimRedeem(dave, _ids(id)); // BOT may push the claim
    assertEq(usdt.balanceOf(dave), 48_500 ether);
  }

  function test_example_frankCancelInsideWindowOnly() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(frank, 30_000 ether);
    vm.prank(manager);
    pool.openCycle();
    uint256 id = _request(frank, 30_000 ether);

    vm.prank(frank);
    pool.cancelRedeem(id);
    assertEq(pool.balanceOf(frank), 30_000 ether, "shares back");
    assertEq(pool.getActiveRequestIds(frank).length, 0);

    uint256 id2 = _request(frank, 30_000 ether); // may re-submit
    vm.prank(manager);
    pool.closeCycle();
    vm.prank(frank);
    vm.expectRevert("window closed");
    pool.cancelRedeem(id2);
  }

  /* ---------------------------------- cycle rules ---------------------------------- */

  function test_cycle_allRequestsShareOneSettlementNav() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(alice, 10_000 ether);
    vm.prank(manager);
    pool.openCycle();
    uint256 a = _request(alice, 10_000 ether); // at NAV 1.00
    _publish(1.1e18);
    uint256 b = _request(bob, 10_000 ether); // at NAV 1.10
    _closeSettleAndFund(1.2e18);

    vm.prank(alice);
    pool.claimRedeem(alice, _ids(a));
    vm.prank(bob);
    pool.claimRedeem(bob, _ids(b));
    assertEq(usdt.balanceOf(alice), 12_000 ether);
    assertEq(usdt.balanceOf(bob), 12_000 ether, "submission-time NAV is irrelevant");
  }

  function test_cycle_settleNeedsNavPublishedAfterClose() public {
    _seedPool();
    vm.prank(manager);
    pool.openCycle();
    _request(bob, 1_000 ether);
    _publish(1.05e18); // published while still open
    vm.startPrank(manager);
    pool.closeCycle();
    vm.expectRevert("nav not published since close");
    pool.settleCycle();
    vm.stopPrank();

    _publish(1.06e18);
    vm.prank(manager);
    pool.settleCycle();
    (, , , , uint256 settlementNav, , , , ) = pool.cycles(1);
    assertEq(settlementNav, 1.06e18);
  }

  function test_cycle_stateMachine() public {
    _seedPool();
    vm.startPrank(manager);
    vm.expectRevert("cycle not open");
    pool.closeCycle();
    vm.expectRevert("cycle not closed");
    pool.settleCycle();

    pool.openCycle();
    assertEq(pool.currentCycleId(), 1);
    vm.expectRevert("cycle in progress");
    pool.openCycle();
    pool.closeCycle();
    vm.expectRevert("cycle in progress");
    pool.openCycle();
    vm.stopPrank();

    _publish(1.01e18);
    vm.startPrank(manager);
    pool.settleCycle(); // empty cycle: no batch
    assertEq(pool.currentBatchId(), 0);
    pool.openCycle();
    assertEq(pool.currentCycleId(), 2);
    vm.stopPrank();
  }

  function test_cycle_noWindowNoRequests() public {
    _seedPool();
    vm.prank(bob);
    vm.expectRevert("window closed");
    pool.requestRedeem(1 ether);
  }

  function test_cycle_subscriptionsContinueDuringWindow() public {
    _seedPool();
    vm.prank(manager);
    pool.openCycle();
    _request(bob, 400_000 ether);
    _subscribe(alice, 100_000 ether); // continuous subscription
    vm.prank(manager);
    pool.closeCycle();
    _subscribe(alice, 100_000 ether); // still open while the cycle awaits settlement
  }

  /* --------------------------------- funding gate --------------------------------- */

  function test_funding_claimsWaitForTheWholeCycle() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(alice, 10_000 ether);
    vm.prank(manager);
    pool.openCycle();
    uint256 a = _request(alice, 10_000 ether);
    _request(bob, 490_000 ether);
    vm.prank(manager);
    pool.closeCycle();
    _publish(1.0e18);
    vm.prank(manager);
    pool.settleCycle();

    // the whole cycle is one batch: a partial recall confirms nothing
    _settleRecall(10_000 ether, 10_000 ether, 0, 0);
    assertEq(pool.confirmedBatchId(), 0);
    assertEq(pool.claimable(a), 0);
    vm.prank(alice);
    vm.expectRevert("not able to claim yet");
    pool.claimRedeem(alice, _ids(a));

    _settleRecall(490_000 ether, 490_000 ether, 0, 0);
    assertEq(pool.claimable(a), 10_000 ether);
    vm.prank(alice);
    pool.claimRedeem(alice, _ids(a));
    assertEq(usdt.balanceOf(alice), 10_000 ether);
  }

  function test_funding_settledPayoutIsReservedOnTheAdapter() public {
    _seedPool();
    vm.prank(manager);
    pool.openCycle();
    _request(bob, 100_000 ether);
    vm.prank(manager);
    pool.closeCycle();
    _publish(1.0e18);
    vm.prank(manager);
    pool.settleCycle();

    assertEq(adapter.onDemandUnfunded(), 100_000 ether, "payout reserved");
    _fundAdapter(100_000 ether);
    assertEq(adapter.maxDeployToSurfin(), 0, "owed cash is not deployable");
    _settleRecall(100_000 ether, 100_000 ether, 0, 0);
    assertEq(adapter.onDemandUnfunded(), 0);
    assertEq(adapter.maxDeployToSurfin(), 100_000 ether, "only the surplus is free");
  }

  /* --------------------------------- claims --------------------------------- */

  function test_claim_rulesAndFee() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(alice, 20_000 ether);
    vm.prank(manager);
    pool.setFeeRate(0.01e18); // 1% Lista cut
    vm.prank(manager);
    pool.openCycle();
    uint256 a = _request(alice, 10_000 ether);
    uint256 b = _request(alice, 10_000 ether);
    _closeSettleAndFund(1.1e18);

    uint256[] memory both = new uint256[](2);
    (both[0], both[1]) = (a, b);
    vm.prank(bob);
    vm.expectRevert("not authorized");
    pool.claimRedeem(alice, both);
    vm.prank(alice);
    vm.expectRevert("not request owner");
    pool.claimRedeem(alice, _ids(999));

    vm.prank(alice);
    pool.claimRedeem(alice, both); // one call, every claimable request
    assertEq(usdt.balanceOf(alice), 21_780 ether, "22,000 less 1%");
    assertEq(usdt.balanceOf(feeReceiver), 220 ether);
    assertEq(pool.getActiveRequestIds(alice).length, 0);

    vm.prank(alice);
    vm.expectRevert("request closed");
    pool.claimRedeem(alice, _ids(a));
    assertEq(pool.totalPendingWithdraw(), 0);
    assertEq(pool.totalConfirmedUnclaimed(), 0);
  }

  function test_claim_roundingRemainderReleasedWithLastClaim() public {
    _seedPool();
    address[3] memory users = [alice, charlie, dave];
    vm.prank(manager);
    pool.openCycle();
    uint256[3] memory ids;
    for (uint256 i = 0; i < 3; i++) {
      vm.prank(bob);
      pool.transfer(users[i], 3);
      ids[i] = _request(users[i], 3); // 3 wei of shares each
    }
    _closeSettleAndFund(1.15e18); // payout = floor(9 x 1.15) = 10, claims pay floor(3.45) = 3 each
    (, , , , , , uint256 payout, , ) = pool.cycles(1);
    assertEq(payout, 10);

    for (uint256 i = 0; i < 3; i++) {
      vm.prank(users[i]);
      pool.claimRedeem(users[i], _ids(ids[i]));
      assertEq(usdt.balanceOf(users[i]), 3);
    }
    assertEq(pool.totalPendingWithdraw(), 0, "remainder released by the last claim");
    assertEq(pool.totalConfirmedUnclaimed(), 0);
    assertEq(usdt.balanceOf(address(pool)), 1, "1 wei of dust stays behind");
  }

  function test_claim_feeSetters() public {
    vm.startPrank(manager);
    vm.expectRevert("fee rate too high");
    pool.setFeeRate(0.3e18 + 1);
    pool.setFeeRate(0.3e18);
    vm.expectRevert("same fee rate");
    pool.setFeeRate(0.3e18);
    vm.expectRevert("feeReceiver is zero");
    pool.setFeeReceiver(address(0));
    vm.stopPrank();

    // a fresh pool cannot turn a fee on before it has a receiver
    RenaissNavPool fresh = RenaissNavPool(
      address(
        new ERC1967Proxy(
          address(new RenaissNavPool()),
          abi.encodeWithSelector(
            RenaissNavPool.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(usdt),
            address(adapter),
            "x",
            "x",
            NAV1
          )
        )
      )
    );
    vm.prank(manager);
    vm.expectRevert("feeReceiver is zero");
    fresh.setFeeRate(0.01e18);
  }

  /* ---------------------------------- NAV rules ---------------------------------- */

  function test_nav_publishIsBoundedPerStep() public {
    vm.startPrank(manager);
    vm.expectRevert("nav delta too large");
    pool.publishNav(1.2e18 + 1);
    vm.expectRevert("nav delta too large");
    pool.publishNav(0.8e18 - 1);
    vm.expectRevert("nav is zero");
    pool.publishNav(0);
    pool.publishNav(1.2e18); // +20%: the default ceiling
    pool.publishNav(0.8e18); // -20% of the window anchor (1.00), not of 1.20
    vm.expectRevert("nav delta too large");
    pool.publishNav(1.2e18 + 1);
    vm.stopPrank();
    assertEq(pool.nav(), 0.8e18);

    vm.prank(alice);
    vm.expectRevert();
    pool.publishNav(1e18);
  }

  function test_nav_deltaSetterBounds() public {
    vm.startPrank(manager);
    vm.expectRevert("invalid nav delta");
    pool.setMaxNavDeltaBps(0);
    vm.expectRevert("invalid nav delta");
    pool.setMaxNavDeltaBps(5_001);
    vm.expectRevert("same nav delta");
    pool.setMaxNavDeltaBps(2_000);
    pool.setMaxNavDeltaBps(500);
    vm.expectRevert("nav delta too large");
    pool.publishNav(1.06e18);
    pool.publishNav(1.05e18);
    vm.stopPrank();
  }

  function test_nav_subscriptionPricesAtLatestNav() public {
    _seedPool();
    _publish(1.2e18);
    _publish(1.25e18); // two bounded steps
    uint256 shares = _subscribe(alice, 100 ether);
    assertEq(shares, 80 ether, "100 / 1.25");
    assertEq(pool.poolNav(), 1_250_100 ether);
  }

  /* ------------------------------ deposit gates ------------------------------ */

  function test_deposit_capIsOnPoolValue() public {
    _subscribe(bob, CAP - MIN_DEPOSIT);
    usdt.mint(alice, 2 * MIN_DEPOSIT);
    vm.startPrank(alice);
    usdt.approve(address(pool), type(uint256).max);
    vm.expectRevert("exceeds cap");
    pool.deposit(MIN_DEPOSIT + 1, alice);
    pool.deposit(MIN_DEPOSIT, alice);
    vm.stopPrank();
    assertEq(pool.poolNav(), CAP);

    // NAV growth fills the cap without new deposits
    _publish(1.01e18);
    usdt.mint(alice, MIN_DEPOSIT);
    vm.prank(alice);
    vm.expectRevert("exceeds cap");
    pool.deposit(MIN_DEPOSIT, alice);
  }

  function test_deposit_minimum() public {
    usdt.mint(alice, MIN_DEPOSIT);
    vm.startPrank(alice);
    usdt.approve(address(pool), MIN_DEPOSIT);
    vm.expectRevert("deposit below minimum");
    pool.deposit(MIN_DEPOSIT - 1, alice);
    pool.deposit(MIN_DEPOSIT, alice);
    vm.stopPrank();
  }

  /// @dev 限制: subscriptions stop; requests, cancels and claims continue.
  function test_restricted_depositPausedStopsSubscriptionsOnly() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(alice, 10_000 ether);
    vm.prank(manager);
    pool.setDepositPaused(true);

    usdt.mint(alice, MIN_DEPOSIT);
    vm.startPrank(alice);
    usdt.approve(address(pool), MIN_DEPOSIT);
    vm.expectRevert("deposit paused");
    pool.deposit(MIN_DEPOSIT, alice);
    vm.stopPrank();

    vm.prank(manager);
    pool.openCycle();
    uint256 a = _request(alice, 5_000 ether);
    vm.prank(alice);
    pool.cancelRedeem(a);
    uint256 b = _request(alice, 10_000 ether);
    _closeSettleAndFund(1.0e18);
    vm.prank(alice);
    pool.claimRedeem(alice, _ids(b));
    assertEq(usdt.balanceOf(alice), 10_000 ether + MIN_DEPOSIT, "payout plus the deposit that was refused");
  }

  function test_pause_freezesFlowsNotTransfers() public {
    _seedPool();
    vm.prank(manager);
    pool.openCycle();
    vm.prank(pauser);
    pool.pause();

    vm.prank(bob);
    pool.transfer(alice, 1 ether); // the share keeps moving
    vm.prank(bob);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    pool.requestRedeem(1 ether);
  }

  /* ------------------------------ share token ------------------------------ */

  function test_shares_freelyTransferableButNeverParkedOnPoolOrAdapter() public {
    _seedPool();
    vm.startPrank(bob);
    pool.approve(market, 1_000 ether);
    vm.expectRevert("invalid receiver");
    pool.transfer(address(pool), 1);
    vm.expectRevert("invalid receiver");
    pool.transfer(address(adapter), 1);
    vm.stopPrank();
    vm.prank(market);
    pool.transferFrom(bob, dave, 1_000 ether);
    assertEq(pool.balanceOf(dave), 1_000 ether);
  }

  function test_shares_escrowInvariant() public {
    _seedPool();
    vm.prank(manager);
    pool.openCycle();
    _request(bob, 300_000 ether);
    uint256 keep = _request(bob, 100_000 ether);
    assertEq(pool.balanceOf(address(pool)), pool.totalEscrowed());
    assertEq(pool.totalEscrowed(), 400_000 ether);

    vm.prank(bob);
    pool.cancelRedeem(keep);
    assertEq(pool.balanceOf(address(pool)), 300_000 ether);
    assertEq(pool.totalSupply(), 1_000_000 ether, "escrow is still supply");

    _closeSettleAndFund(1.0e18);
    assertEq(pool.balanceOf(address(pool)), 0, "burned at settlement");
    assertEq(pool.totalEscrowed(), 0);
    assertEq(pool.totalSupply(), 700_000 ether);
  }

  /// @dev no per-cycle ceiling: a single cycle may redeem the whole pool.
  function test_cycle_wholePoolCanBeRequested() public {
    _seedPool();
    vm.prank(manager);
    pool.openCycle();
    _request(bob, 1_000_000 ether); // the whole pool
    _closeSettleAndFund(1.0e18);
    assertEq(pool.totalSupply(), 0, "fully redeemed");
  }

  /* ------------------------------ review follow-ups ------------------------------ */

  /// @dev the delta bound is a weekly bound: publications inside one window cannot compound.
  function test_nav_boundIsPerWindowNotPerCall() public {
    vm.startPrank(manager);
    pool.publishNav(1.2e18);
    vm.expectRevert("nav delta too large");
    pool.publishNav(1.44e18); // +20% on top of +20%, same window
    pool.publishNav(1.15e18); // a correction inside the window is fine
    vm.stopPrank();

    vm.warp(block.timestamp + 7 days); // new window anchored at 1.15
    vm.startPrank(manager);
    assertEq(pool.navAnchor(), 1e18, "anchor moves lazily, on the next publish");
    pool.publishNav(1.38e18); // +20% of 1.15
    assertEq(pool.navAnchor(), 1.15e18);
    vm.expectRevert("nav delta too large");
    pool.publishNav(1.38e18 + 1);
    vm.stopPrank();
  }

  function test_rescue_cannotMoveEscrowedShares() public {
    _seedPool();
    vm.prank(manager);
    pool.openCycle();
    _request(bob, 10_000 ether);
    vm.prank(admin);
    vm.expectRevert("cannot rescue own token");
    pool.emergencyWithdraw(address(pool), 10_000 ether, admin);
    assertEq(pool.balanceOf(address(pool)), pool.totalEscrowed());
  }

  function test_fee_frozenAtSettlement() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(alice, 10_000 ether);
    vm.prank(manager);
    pool.setFeeRate(0.01e18);
    vm.prank(manager);
    pool.openCycle();
    uint256 id = _request(alice, 10_000 ether);
    _closeSettleAndFund(1.0e18);

    vm.prank(manager);
    pool.setFeeRate(0.1e18); // changed after settlement: next cycle only
    assertEq(pool.claimable(id), 9_900 ether);
    vm.prank(alice);
    pool.claimRedeem(alice, _ids(id));
    assertEq(usdt.balanceOf(alice), 9_900 ether);
    assertEq(usdt.balanceOf(feeReceiver), 100 ether);
  }

  function test_closeCycle_blockedWhilePaused() public {
    _seedPool();
    vm.prank(manager);
    pool.openCycle();
    vm.prank(pauser);
    pool.pause();
    vm.prank(manager);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    pool.closeCycle();
  }

  function test_request_rejectsWorthlessAndHonoursMinWithdraw() public {
    _seedPool();
    vm.prank(manager);
    pool.openCycle();
    _publish(0.9e18);
    vm.prank(bob);
    vm.expectRevert("request below 1 wei");
    pool.requestRedeem(1); // 1 wei of shares is worth 0 at 0.9

    vm.prank(manager);
    pool.setMinWithdraw(1_000 ether);
    vm.prank(bob);
    vm.expectRevert("below min withdraw");
    pool.requestRedeem(500 ether); // 450 USDT, not a full exit
    vm.prank(bob);
    pool.transfer(alice, 500 ether);
    vm.prank(alice);
    pool.requestRedeem(500 ether); // dust exit: alice's whole balance
  }

  /// @dev a cycle whose payout rounds to zero burns its shares but books no batch.
  function test_settle_zeroPayoutBooksNoBatch() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(alice, 1);
    vm.prank(manager);
    pool.openCycle();
    uint256 id = _request(alice, 1); // worth 1 wei at NAV 1.00
    _closeSettleAndFund(0.9e18); // payout floor(0.9) = 0
    assertEq(pool.currentBatchId(), 0, "no batch for nothing");
    assertEq(pool.totalSupply(), 1_000_000 ether - 1, "share burned anyway");
    vm.prank(alice);
    pool.claimRedeem(alice, _ids(id)); // pays 0, closes the request
    assertEq(pool.getActiveRequestIds(alice).length, 0);
  }

  function test_view_unfundedPayout() public {
    _seedPool();
    vm.prank(manager);
    pool.openCycle();
    _request(bob, 100_000 ether);
    vm.prank(manager);
    pool.closeCycle();
    _publish(1.0e18);
    vm.prank(manager);
    pool.settleCycle();
    assertEq(pool.unfundedPayout(), 100_000 ether);
    _settleRecall(40_000 ether, 40_000 ether, 0, 0); // partial: parked as quota
    assertEq(pool.unfundedPayout(), 60_000 ether);
    _settleRecall(60_000 ether, 60_000 ether, 0, 0);
    assertEq(pool.unfundedPayout(), 0);
  }
}
