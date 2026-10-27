// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";
import "../../src/surfin/RenaissNavPool.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

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
    pool.deposit(amount, who, 0);
    vm.stopPrank();
    shares = pool.balanceOf(who) - before;
  }

  /// @dev the PRD baseline: 1,000,000 shares at NAV 1.00, all deployed to the partner.
  function _seedPool() internal {
    _subscribe(bob, 1_000_000 ether);
    vm.prank(manager);
    adapter.deployToSurfin(1_000_000 ether);
    assertEq(pool.totalSupply(), 1_000_000 ether);
    assertEq(pool.poolNav(), 1_000_000 ether);
  }

  function _publish(uint256 nav_) internal {
    _publishOver(nav_, 0);
  }

  /// @dev a week later, publish `nav_` and release it over `duration`
  function _publishOver(uint256 nav_, uint256 duration) internal {
    vm.warp(block.timestamp + 7 days);
    vm.prank(manager);
    pool.publishNav(nav_, duration);
  }

  function _request(address who, uint256 shares) internal returns (uint256 id) {
    vm.prank(who);
    id = pool.requestRedeem(shares);
  }

  function _ids(uint256 a) internal pure returns (uint256[] memory r) {
    r = new uint256[](1);
    r[0] = a;
  }

  /// @dev close, publish the settlement NAV, and settle: the manager brings in the payout.
  function _settle(uint256 settlementNav) internal returns (uint256 payout) {
    uint256 epochId = pool.currentEpochId();
    vm.prank(manager);
    pool.closeEpoch();
    _publish(settlementNav);
    (, uint256 requested, , , , , , ) = pool.epochs(epochId);
    payout = (requested * settlementNav) / 1e18;
    usdt.mint(manager, payout);
    vm.startPrank(manager);
    usdt.approve(address(pool), payout);
    pool.settleEpoch();
    vm.stopPrank();
    (, , , , uint256 settled, uint256 booked, , ) = pool.epochs(epochId);
    assertEq(settled, settlementNav, "settlement NAV recorded");
    assertEq(booked, payout, "payout recorded");
  }

  /// @dev one-shot claim of a whole epoch, by anyone.
  function _claimEpoch(uint256 epochId) internal {
    vm.prank(market);
    pool.claimRedeem(pool.getEpochRequestIds(epochId));
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
    pool.openEpoch();
    _request(charlie, 50_000 ether);
    assertEq(pool.balanceOf(charlie), 0, "shares escrowed");
    assertEq(pool.balanceOf(address(pool)), 50_000 ether);

    uint256 payout = _settle(1.12e18);
    assertEq(payout, 56_000 ether, "50,000 x 1.12");
    assertEq(pool.totalSupply(), 950_000 ether, "escrowed shares burned at settlement");
    assertEq(usdt.balanceOf(address(pool)), 56_000 ether, "the partner's money is in the pool");
    assertEq(pool.totalOwed(), 56_000 ether);

    _claimEpoch(1);
    assertEq(usdt.balanceOf(charlie), 56_000 ether);
    assertEq(pool.totalOwed(), 0);
    assertEq(usdt.balanceOf(address(pool)), 0, "pool fully paid out");
  }

  function test_example_daveForwardPricedDown() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(dave, 50_000 ether);
    _publish(1.08e18);
    vm.prank(manager);
    pool.openEpoch();
    _request(dave, 50_000 ether);

    uint256 payout = _settle(0.97e18);
    assertEq(payout, 48_500 ether, "50,000 x 0.97");
    _claimEpoch(1);
    assertEq(usdt.balanceOf(dave), 48_500 ether);
  }

  function test_example_frankCancelInsideWindowOnly() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(frank, 30_000 ether);
    vm.prank(manager);
    pool.openEpoch();
    uint256 id = _request(frank, 30_000 ether);

    vm.prank(frank);
    pool.cancelRedeem(id);
    assertEq(pool.balanceOf(frank), 30_000 ether, "shares back");
    vm.prank(frank);
    vm.expectRevert("request cancelled");
    pool.cancelRedeem(id);

    uint256 id2 = _request(frank, 30_000 ether); // may re-submit
    vm.prank(manager);
    pool.closeEpoch();
    vm.prank(frank);
    vm.expectRevert("window closed");
    pool.cancelRedeem(id2);

    // the cancelled id sits in the epoch's list and is skipped by the payout
    _publish(1.0e18);
    usdt.mint(manager, 30_000 ether);
    vm.startPrank(manager);
    usdt.approve(address(pool), 30_000 ether);
    pool.settleEpoch();
    vm.stopPrank();
    _claimEpoch(1);
    assertEq(usdt.balanceOf(frank), 30_000 ether, "paid once, for the live request");
  }

  /* ---------------------------------- epoch rules ---------------------------------- */

  function test_epoch_allRequestsShareOneSettlementNav() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(alice, 10_000 ether);
    vm.prank(manager);
    pool.openEpoch();
    _request(alice, 10_000 ether); // at NAV 1.00
    _publish(1.1e18);
    _request(bob, 10_000 ether); // at NAV 1.10
    _settle(1.2e18);
    _claimEpoch(1);
    assertEq(usdt.balanceOf(alice), 12_000 ether);
    assertEq(usdt.balanceOf(bob), 12_000 ether, "submission-time NAV is irrelevant");
  }

  function test_epoch_settleNeedsNavPublishedAfterClose() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    _request(bob, 1_000 ether);
    _publish(1.05e18); // published while still open
    vm.startPrank(manager);
    pool.closeEpoch();
    vm.expectRevert("nav not published since close");
    pool.settleEpoch();
    vm.stopPrank();

    _publish(1.06e18);
    usdt.mint(manager, 1_060 ether);
    vm.startPrank(manager);
    usdt.approve(address(pool), 1_060 ether);
    pool.settleEpoch();
    vm.stopPrank();
    (, , , , uint256 settlementNav, , , ) = pool.epochs(1);
    assertEq(settlementNav, 1.06e18);
  }

  function test_epoch_stateMachine() public {
    _seedPool();
    vm.startPrank(manager);
    vm.expectRevert("epoch not open");
    pool.closeEpoch();
    vm.expectRevert("epoch not closed");
    pool.settleEpoch();

    pool.openEpoch();
    assertEq(pool.currentEpochId(), 1);
    vm.expectRevert("epoch in progress");
    pool.openEpoch();
    pool.closeEpoch();
    vm.expectRevert("epoch in progress");
    pool.openEpoch();
    vm.stopPrank();

    _publish(1.01e18);
    uint256 managerBefore = usdt.balanceOf(manager);
    vm.startPrank(manager);
    pool.settleEpoch(); // empty epoch: nothing to bring in
    assertEq(usdt.balanceOf(manager), managerBefore);
    pool.openEpoch();
    assertEq(pool.currentEpochId(), 2);
    vm.stopPrank();
  }

  function test_epoch_noWindowNoRequests() public {
    _seedPool();
    vm.prank(bob);
    vm.expectRevert("window closed");
    pool.requestRedeem(1 ether);
  }

  function test_epoch_subscriptionsContinueDuringWindow() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    _request(bob, 400_000 ether);
    _subscribe(alice, 100_000 ether); // continuous subscription
    vm.prank(manager);
    pool.closeEpoch();
    _subscribe(alice, 100_000 ether); // still open while the epoch awaits settlement
  }

  /// @dev no per-epoch ceiling: a single epoch may redeem the whole pool.
  function test_epoch_wholePoolCanBeRequested() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    _request(bob, 1_000_000 ether);
    _settle(1.0e18);
    _claimEpoch(1);
    assertEq(pool.totalSupply(), 0, "fully redeemed");
    assertEq(usdt.balanceOf(bob), 1_000_000 ether);
  }

  /* -------------------------------- settlement -------------------------------- */

  function test_settle_bringsInExactlyThePayout() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    _request(bob, 100_000 ether);
    vm.prank(manager);
    pool.closeEpoch();
    _publish(1.0e18);

    // no allowance, no settlement
    vm.prank(manager);
    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 100_000 ether)
    );
    pool.settleEpoch();

    usdt.mint(manager, 150_000 ether);
    vm.startPrank(manager);
    usdt.approve(address(pool), 150_000 ether);
    pool.settleEpoch();
    vm.stopPrank();
    assertEq(usdt.balanceOf(manager), 50_000 ether, "exactly 100,000 pulled");
    assertEq(usdt.balanceOf(address(pool)), 100_000 ether);
    assertEq(pool.totalOwed(), 100_000 ether);
    assertEq(pool.totalEscrowed(), 0, "escrow burned");
    assertEq(pool.totalSupply(), 900_000 ether);
  }

  function test_settle_doesNotTouchTheAdapter() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    _request(bob, 100_000 ether);
    _settle(1.0e18);
    assertEq(adapter.idleBalance(), 0, "no cash moved through the adapter");
    assertEq(adapter.onDemandUnfunded(), 0, "nothing queued on the template rail");
    assertEq(pool.totalPendingWithdraw(), 0);

    // the template rail cannot push cash into this pool either
    _fundAdapter(1 ether);
    vm.prank(bot);
    vm.expectRevert("quota exceeds pending");
    adapter.finishLockedWithdraw(1 ether);
  }

  /// @dev an epoch whose payout rounds to zero burns its shares and pulls nothing.
  function test_settle_zeroPayoutPullsNothing() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(alice, 1);
    vm.prank(manager);
    pool.openEpoch();
    uint256 id = _request(alice, 1); // worth 1 wei at NAV 1.00
    uint256 payout = _settle(0.9e18); // floor(0.9) = 0
    assertEq(payout, 0);
    assertEq(pool.totalSupply(), 1_000_000 ether - 1, "share burned anyway");
    _claimEpoch(1);
    (, , , , bool claimed) = pool.requests(id);
    assertTrue(claimed);
    assertEq(pool.totalOwed(), 0);
  }

  /* ---------------------------------- payouts ---------------------------------- */

  function test_claim_wholeEpochInOneGoByAnyone() public {
    _seedPool();
    address[3] memory users = [alice, charlie, dave];
    uint256[3] memory ids;
    vm.prank(manager);
    pool.openEpoch();
    for (uint256 i = 0; i < 3; i++) {
      vm.prank(bob);
      pool.transfer(users[i], 10_000 ether);
      ids[i] = _request(users[i], 10_000 ether);
    }
    _settle(1.1e18);

    vm.prank(market); // not a role holder
    pool.claimRedeem(pool.getEpochRequestIds(1));
    for (uint256 i = 0; i < 3; i++) assertEq(usdt.balanceOf(users[i]), 11_000 ether);
    assertEq(pool.totalOwed(), 0);
    assertEq(usdt.balanceOf(address(pool)), 0);

    // claiming again is a no-op
    vm.prank(market);
    pool.claimRedeem(pool.getEpochRequestIds(1));
    assertEq(usdt.balanceOf(alice), 11_000 ether);
  }

  function test_claim_inBatches() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    uint256 a = _request(bob, 1_000 ether);
    uint256 b = _request(bob, 2_000 ether);
    uint256 c = _request(bob, 3_000 ether);
    _settle(1.0e18);

    uint256[] memory first = new uint256[](2);
    (first[0], first[1]) = (a, b);
    pool.claimRedeem(first);
    assertEq(usdt.balanceOf(bob), 3_000 ether);
    assertEq(pool.totalOwed(), 3_000 ether);
    pool.claimRedeem(_ids(c));
    assertEq(usdt.balanceOf(bob), 6_000 ether);
    assertEq(pool.totalOwed(), 0);
  }

  function test_claim_rejectsUnknownAndUnsettled() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    uint256 id = _request(bob, 1_000 ether);

    vm.expectRevert("unknown request");
    pool.claimRedeem(_ids(999));
    vm.expectRevert("epoch not settled");
    pool.claimRedeem(_ids(id)); // still open
    vm.prank(manager);
    pool.closeEpoch();
    vm.expectRevert("epoch not settled");
    pool.claimRedeem(_ids(id)); // closed, not settled
  }

  function test_claim_feeFrozenAtSettlementAndRemainderToFeeReceiver() public {
    _seedPool();
    vm.prank(manager);
    pool.setFeeRate(0.01e18); // 1%
    address[3] memory users = [alice, charlie, dave];
    vm.prank(manager);
    pool.openEpoch();
    for (uint256 i = 0; i < 3; i++) {
      vm.prank(bob);
      pool.transfer(users[i], 3);
      _request(users[i], 3); // 3 wei of shares each
    }
    uint256 payout = _settle(1.15e18); // floor(9 x 1.15) = 10; each pays floor(3.45) = 3
    assertEq(payout, 10);

    vm.prank(manager);
    pool.setFeeRate(0.1e18); // changed after settlement: next epoch only
    _claimEpoch(1);
    for (uint256 i = 0; i < 3; i++) assertEq(usdt.balanceOf(users[i]), 3, "1% of 3 wei rounds to 0");
    assertEq(usdt.balanceOf(feeReceiver), 1, "the rounding remainder");
    assertEq(pool.totalOwed(), 0);
    assertEq(usdt.balanceOf(address(pool)), 0);
  }

  function test_claim_feeSplit() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(alice, 20_000 ether);
    vm.prank(manager);
    pool.setFeeRate(0.01e18);
    vm.prank(manager);
    pool.openEpoch();
    _request(alice, 20_000 ether);
    _settle(1.1e18);
    _claimEpoch(1);
    assertEq(usdt.balanceOf(alice), 21_780 ether, "22,000 less 1%");
    assertEq(usdt.balanceOf(feeReceiver), 220 ether);
  }

  function test_fee_setters() public {
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

  /// @dev the contract applies whatever the multisig publishes: only zero (and values
  ///      beyond uint128, see test_release_bounds) are rejected; the move itself is unbounded.
  function test_nav_publishRules() public {
    vm.prank(alice);
    vm.expectRevert();
    pool.publishNav(1.1e18, 0);

    vm.startPrank(manager);
    vm.expectRevert("nav is zero");
    pool.publishNav(0, 0);
    vm.expectEmit(false, false, false, true, address(pool));
    emit RenaissNavPool.NavPublished(1e18, 3e18, 1e18, 0);
    pool.publishNav(3e18, 0); // no bound
    pool.publishNav(0.5e18, 0);
    vm.stopPrank();
    assertEq(pool.nav(), 0.5e18);
    assertEq(pool.navUpdatedAt(), block.timestamp);
  }

  function test_nav_subscriptionPricesAtNav_step() public {
    _seedPool();
    _publish(1.25e18);
    assertEq(pool.nav(), pool.publishedNav(), "a step publish applies at once");
    uint256 shares = _subscribe(alice, 100 ether);
    assertEq(shares, 80 ether, "100 / 1.25");
    assertEq(pool.poolNav(), 1_250_100 ether);
  }

  /* --------------------------------- NAV release --------------------------------- */

  function test_release_riseIsLinear() public {
    _seedPool();
    _publishOver(1.1e18, 7 days);
    assertEq(pool.nav(), 1e18, "starts from the current price");
    assertEq(pool.publishedNav(), 1.1e18);
    assertEq(pool.currentLockedNav(), 0.1e18);
    assertEq(pool.poolNav(), 1_000_000 ether, "valued at the current price");
    assertEq(pool.totalPrincipal(), 1_100_000 ether, "booked at the published NAV");

    vm.warp(block.timestamp + 3.5 days);
    assertEq(pool.nav(), 1.05e18);
    assertEq(_subscribe(alice, 105 ether), 100 ether, "minted at the current price");

    vm.warp(block.timestamp + 3.5 days);
    assertEq(pool.nav(), 1.1e18);
    assertEq(pool.currentLockedNav(), 0);
    vm.warp(block.timestamp + 30 days);
    assertEq(pool.nav(), 1.1e18, "stays at the published NAV");
  }

  function test_release_dropIsLinear() public {
    _seedPool();
    _publishOver(0.9e18, 7 days);
    assertEq(pool.nav(), 1e18);
    assertEq(pool.currentLockedNav(), -0.1e18);
    vm.warp(block.timestamp + 3.5 days);
    assertEq(pool.nav(), 0.95e18);
    assertEq(_subscribe(alice, 190 ether), 200 ether);
    vm.warp(block.timestamp + 3.5 days);
    assertEq(pool.nav(), 0.9e18);
  }

  function test_release_zeroDurationIsAtOnce() public {
    _seedPool();
    _publishOver(1.2e18, 0);
    assertEq(pool.nav(), 1.2e18);
    assertEq(pool.lockedNav(), 0);
    _publishOver(0.8e18, 0);
    assertEq(pool.nav(), 0.8e18);
  }

  /// @dev combine-and-reset: a publish mid-release starts from the current price, carrying
  ///      what was not released yet, so the price never jumps.
  function test_release_publishMidReleaseCarriesRemainder() public {
    _seedPool();
    _publishOver(1.1e18, 7 days);
    vm.warp(block.timestamp + 3.5 days); // price 1.05

    vm.prank(manager);
    pool.publishNav(1.2e18, 7 days);
    assertEq(pool.nav(), 1.05e18, "continuous across the publish");
    assertEq(pool.lockedNav(), 0.15e18, "remainder 0.05 + new rise 0.10");
    vm.warp(block.timestamp + 3.5 days);
    assertEq(pool.nav(), 1.125e18);
    vm.warp(block.timestamp + 3.5 days);
    assertEq(pool.nav(), 1.2e18);

    // reversal mid-release: from 1.2 towards 1.0, then back up to 1.06 from wherever it is
    vm.prank(manager);
    pool.publishNav(1.0e18, 4 days);
    vm.warp(block.timestamp + 1 days);
    assertEq(pool.nav(), 1.15e18);
    vm.prank(manager);
    pool.publishNav(1.06e18, 2 days);
    assertEq(pool.nav(), 1.15e18, "no jump on a reversal either");
    vm.warp(block.timestamp + 2 days);
    assertEq(pool.nav(), 1.06e18);
  }

  /// @dev a 0-second publish is the correction path: it applies at once, mid-release too.
  function test_release_correctionAppliesAtOnce() public {
    _seedPool();
    _publishOver(0.5e18, 7 days); // a wrong, too-low NAV being released
    vm.warp(block.timestamp + 1 days);
    vm.prank(manager);
    pool.publishNav(1.02e18, 0);
    assertEq(pool.nav(), 1.02e18);
    assertEq(pool.currentLockedNav(), 0);
  }

  function test_release_bounds() public {
    vm.startPrank(manager);
    vm.expectRevert("release too long");
    pool.publishNav(1.1e18, 7 days + 1);
    vm.expectRevert("nav too large");
    pool.publishNav(uint256(type(uint128).max) + 1, 0);
    pool.publishNav(1.1e18, 7 days);
    vm.stopPrank();
    assertEq(pool.navReleaseDuration(), 7 days);
    assertEq(pool.MAX_NAV_RELEASE(), 7 days);
  }

  function test_release_eventCarriesTheCurve() public {
    _seedPool();
    _publishOver(1.1e18, 7 days);
    vm.warp(block.timestamp + 3.5 days);
    vm.expectEmit(false, false, false, true, address(pool));
    emit RenaissNavPool.NavPublished(1.1e18, 1.2e18, 1.05e18, 2 days);
    vm.prank(manager);
    pool.publishNav(1.2e18, 2 days);
  }

  /// @dev settlement pays at the published NAV, whatever the price still being released.
  function test_release_settlementUsesPublishedNav() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    _request(bob, 100_000 ether);
    vm.prank(manager);
    pool.closeEpoch();
    _publishOver(1.2e18, 7 days);
    assertEq(pool.nav(), 1e18);

    usdt.mint(manager, 120_000 ether);
    vm.startPrank(manager);
    usdt.approve(address(pool), 120_000 ether);
    pool.settleEpoch();
    vm.stopPrank();
    (, , , , uint256 settlementNav, uint256 payout, , ) = pool.epochs(1);
    assertEq(settlementNav, 1.2e18);
    assertEq(payout, 120_000 ether);
    _claimEpoch(1);
    assertEq(usdt.balanceOf(bob), 120_000 ether);
  }

  /// @dev the cap is measured on the published value: it does not drift during a release,
  ///      and a deposit below the published NAV is counted at what its shares are worth.
  function test_release_capOnPublishedValue() public {
    _subscribe(bob, 2_000_000 ether);
    _publishOver(1.25e18, 7 days); // published value 2,500,000, price still 1.00
    assertEq(pool.totalPrincipal(), 2_500_000 ether);
    vm.warp(block.timestamp + 3 days);
    assertEq(pool.totalPrincipal(), 2_500_000 ether, "no drift while the price moves");
    vm.warp(block.timestamp - 3 days);

    usdt.mint(alice, 500_000 ether);
    vm.startPrank(alice);
    usdt.approve(address(pool), type(uint256).max);
    vm.expectRevert("exceeds cap"); // 450,000 shares are worth 562,500 at 1.25
    pool.deposit(450_000 ether, alice, 0);
    pool.deposit(400_000 ether, alice, 0); // 400,000 shares, worth exactly the 500,000 left
    vm.stopPrank();
    assertEq(pool.totalPrincipal(), CAP);
  }

  /// @dev the request value check uses the current price, the one the holder sees.
  function test_release_requestValueUsesCurrentPrice() public {
    _seedPool();
    vm.prank(manager);
    pool.setMinWithdraw(1_000 ether);
    vm.prank(manager);
    pool.openEpoch();
    _publishOver(0.5e18, 7 days);
    vm.warp(block.timestamp + 3.5 days); // price 0.75, published 0.50
    vm.prank(bob);
    vm.expectRevert("below min withdraw");
    pool.requestRedeem(1_300 ether); // 975 at the current price
    _request(bob, 1_400 ether); // 1,050 at the current price, 700 at the published NAV
  }

  /// forge-config: default.fuzz.runs = 512
  function testFuzz_release_staysBetweenAndIsMonotonic(
    uint256 fromNav,
    uint256 toNav,
    uint256 duration,
    uint256 t1,
    uint256 t2
  ) public {
    fromNav = bound(fromNav, 1e12, 1e24);
    toNav = bound(toNav, 1e12, 1e24);
    duration = bound(duration, 1, 7 days);
    t1 = bound(t1, 0, duration + 1 days);
    t2 = bound(t2, t1, duration + 1 days);
    vm.startPrank(manager);
    pool.publishNav(fromNav, 0);
    pool.publishNav(toNav, duration);
    vm.stopPrank();
    uint256 start = block.timestamp;
    (uint256 lo, uint256 hi) = fromNav < toNav ? (fromNav, toNav) : (toNav, fromNav);

    vm.warp(start + t1);
    uint256 p1 = pool.nav();
    vm.warp(start + t2);
    uint256 p2 = pool.nav();
    assertGe(p1, lo);
    assertLe(p1, hi);
    assertGe(p2, lo);
    assertLe(p2, hi);
    if (toNav >= fromNav) assertGe(p2, p1, "a rise never goes back");
    else assertLe(p2, p1, "a drop never goes back");
    if (t2 >= duration) assertEq(p2, toNav, "reaches the published NAV");
  }

  /// @dev during a drop release the asset sent in is what binds the cap.
  function test_release_capDuringDropBindsOnAmount() public {
    _subscribe(bob, 2_000_000 ether);
    _publishOver(0.8e18, 7 days); // published value 1,600,000, price still 1.00
    usdt.mint(alice, 1_500_000 ether);
    vm.startPrank(alice);
    usdt.approve(address(pool), type(uint256).max);
    vm.expectRevert("exceeds cap"); // 1,600,000 + 1,500,000 sent in > 3,000,000
    pool.deposit(1_500_000 ether, alice, 0);
    pool.deposit(1_400_000 ether, alice, 0); // exactly the cap in asset terms
    vm.stopPrank();
    assertEq(pool.totalPrincipal(), 2_720_000 ether, "3,400,000 shares at 0.80");
  }

  /// @dev what a subscription made during a release is settled at: a rise release lets
  ///      it capture the unreleased part, a drop release makes it pay that part.
  function test_release_subscriptionCycleBothDirections() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();

    _publishOver(1.1e18, 7 days); // rise, price still 1.00
    uint256 up = _subscribe(alice, 100_000 ether);
    assertEq(up, 100_000 ether);
    _request(alice, up);
    vm.prank(manager);
    pool.closeEpoch();
    _publishOver(1.1e18, 0);
    usdt.mint(manager, 110_000 ether);
    vm.startPrank(manager);
    usdt.approve(address(pool), 110_000 ether);
    pool.settleEpoch();
    pool.openEpoch();
    vm.stopPrank();
    _claimEpoch(1);
    assertEq(usdt.balanceOf(alice), 110_000 ether, "the unreleased rise went to the subscriber");

    _publishOver(0.99e18, 7 days); // drop, price still 1.10
    uint256 down = _subscribe(charlie, 110_000 ether);
    assertEq(down, 100_000 ether);
    _request(charlie, down);
    vm.prank(manager);
    pool.closeEpoch();
    _publishOver(0.99e18, 0);
    usdt.mint(manager, 99_000 ether);
    vm.startPrank(manager);
    usdt.approve(address(pool), 99_000 ether);
    pool.settleEpoch();
    vm.stopPrank();
    _claimEpoch(2);
    assertEq(usdt.balanceOf(charlie), 99_000 ether, "the subscriber paid the unreleased drop");
  }

  /// @dev publishing the same value with the remaining time unlocks settlement and keeps
  ///      the price on its original line.
  function test_release_republishWithRemainingTimeKeepsTheCurve() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    _request(bob, 1_000 ether);
    _publishOver(1.1e18, 7 days);
    uint256 end = block.timestamp + 7 days;
    vm.warp(block.timestamp + 1 days);
    vm.prank(manager);
    pool.closeEpoch();
    vm.warp(block.timestamp + 1 days);
    uint256 before = pool.nav();
    uint256 remaining = pool.navReleaseStart() + pool.navReleaseDuration() - block.timestamp;
    vm.prank(manager);
    pool.publishNav(1.1e18, remaining);
    assertEq(pool.nav(), before);
    vm.warp(end - 2.5 days);
    uint256 rise = 0.1e18;
    assertApproxEqAbs(pool.nav(), 1.1e18 - (rise * 2.5 days) / 7 days, 1, "on the original line");
    vm.warp(end);
    assertEq(pool.nav(), 1.1e18);

    usdt.mint(manager, 1_100 ether);
    vm.startPrank(manager);
    usdt.approve(address(pool), 1_100 ether);
    pool.settleEpoch();
    vm.stopPrank();
  }

  /// @dev the uint128 ceiling keeps the signed math in range at the extremes.
  function test_release_extremes() public {
    uint256 top = type(uint128).max;
    vm.startPrank(manager);
    pool.publishNav(top, 7 days);
    vm.warp(block.timestamp + 3 days);
    pool.publishNav(1, 7 days);
    vm.warp(block.timestamp + 2 days);
    uint256 mid = pool.nav();
    assertGe(mid, 1);
    assertLe(mid, top);
    pool.publishNav(top, 3 days);
    assertEq(pool.nav(), mid, "continuous at the extremes");
    vm.warp(block.timestamp + 1 days);
    assertGt(pool.nav(), mid);
    vm.warp(block.timestamp + 2 days);
    assertEq(pool.nav(), top);
    vm.stopPrank();
    assertEq(pool.poolNav(), 0, "no supply");

    RenaissNavPool impl = new RenaissNavPool();
    vm.expectRevert("nav too large");
    new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(
        impl.initialize.selector,
        admin,
        manager,
        pauser,
        bot,
        address(usdt),
        address(adapter),
        "x",
        "x",
        top + 1
      )
    );
  }

  /// forge-config: default.fuzz.runs = 512
  /// @dev chained publishes (mid-release, same block, reversals, steps): the price never
  ///      jumps on a release publish, stays within each segment and reaches its target.
  function testFuzz_release_chainedPublishes(uint256 seed) public {
    for (uint256 k = 0; k < 4; k++) {
      uint256 r = uint256(keccak256(abi.encode(seed, k)));
      uint256 newNav = bound(r, 1, type(uint128).max);
      uint256 duration = bound(r >> 128, 0, 7 days);
      if ((r >> 8) % 4 == 0) duration = 0;
      uint256 warpBy = bound(r >> 64, 0, 8 days);
      if ((r >> 16) % 3 == 0) warpBy = 0; // same block

      uint256 p = pool.nav();
      vm.prank(manager);
      pool.publishNav(newNav, duration);
      if (duration == 0) assertEq(pool.nav(), newNav, "a step applies at once");
      else assertEq(pool.nav(), p, "no jump on a release publish");

      uint256 start = block.timestamp;
      vm.warp(start + warpBy);
      uint256 q = pool.nav();
      (uint256 lo, uint256 hi) = p < newNav ? (p, newNav) : (newNav, p);
      if (duration == 0) assertEq(q, newNav);
      else {
        assertGe(q, lo);
        assertLe(q, hi);
      }
      if (warpBy >= duration) assertEq(q, newNav, "reaches the target");
      assertGt(q, 0);
    }
  }

  /* ------------------------------ deposit gates ------------------------------ */

  function test_deposit_capOnPublishedValue_step() public {
    _subscribe(bob, CAP - MIN_DEPOSIT);
    usdt.mint(alice, 2 * MIN_DEPOSIT);
    vm.startPrank(alice);
    usdt.approve(address(pool), type(uint256).max);
    vm.expectRevert("exceeds cap");
    pool.deposit(MIN_DEPOSIT + 1, alice, 0);
    pool.deposit(MIN_DEPOSIT, alice, 0);
    vm.stopPrank();
    assertEq(pool.totalPrincipal(), CAP, "the cap measure");

    // NAV growth fills the cap without new deposits
    _publish(1.01e18);
    usdt.mint(alice, MIN_DEPOSIT);
    vm.prank(alice);
    vm.expectRevert("exceeds cap");
    pool.deposit(MIN_DEPOSIT, alice, 0);
  }

  function test_deposit_minimum() public {
    usdt.mint(alice, MIN_DEPOSIT);
    vm.startPrank(alice);
    usdt.approve(address(pool), MIN_DEPOSIT);
    vm.expectRevert("deposit below minimum");
    pool.deposit(MIN_DEPOSIT - 1, alice, 0);
    pool.deposit(MIN_DEPOSIT, alice, 0);
    vm.stopPrank();
  }

  /* -------------------------- deposit slippage (minShares) -------------------------- */

  /// @dev the quote a front end would take: shares at the current `nav()`
  function _quote(uint256 amount) internal view returns (uint256) {
    return (amount * 1e18) / pool.nav();
  }

  function _fundAlice(uint256 amount) internal {
    usdt.mint(alice, amount);
    vm.prank(alice);
    usdt.approve(address(pool), type(uint256).max);
  }

  /// @dev a NAV published between the quote and the execution is caught; the exact quote passes
  function test_deposit_minShares_revertsWhenNavRisesBeforeExecution() public {
    _fundAlice(20_000 ether);
    uint256 quote = _quote(10_000 ether);
    assertEq(quote, 10_000 ether);

    vm.prank(manager);
    pool.publishNav(1.1e18, 0);

    vm.prank(alice);
    vm.expectRevert("shares below minimum");
    pool.deposit(10_000 ether, alice, quote);

    uint256 requote = _quote(10_000 ether);
    vm.prank(alice);
    vm.expectRevert("shares below minimum");
    pool.deposit(10_000 ether, alice, requote + 1);
    vm.prank(alice);
    pool.deposit(10_000 ether, alice, requote);
    assertEq(pool.balanceOf(alice), requote, "minted exactly the quote");
  }

  /// @dev a release keeps raising `nav()` after the quote; the floor bounds the drift
  function test_deposit_minShares_boundsTheReleaseGlide() public {
    _fundAlice(20_000 ether);
    vm.prank(manager);
    pool.publishNav(1.1e18, 7 days);
    uint256 quote = _quote(10_000 ether);

    vm.warp(block.timestamp + 1 days);
    assertLt(_quote(10_000 ether), quote, "the price kept rising");
    vm.prank(alice);
    vm.expectRevert("shares below minimum");
    pool.deposit(10_000 ether, alice, quote);

    // a day of a 10% rise over 7 days is about 1.43%; a 2% tolerance absorbs it
    vm.prank(alice);
    pool.deposit(10_000 ether, alice, (quote * 98) / 100);
    assertEq(pool.balanceOf(alice), _quote(10_000 ether), "minted at the execution-time nav");
  }

  /// @dev a NAV pushed up just before the deposit would otherwise mint dust
  function test_deposit_minShares_stopsADustMint() public {
    _fundAlice(10_000 ether);
    uint256 quote = _quote(1_000 ether);
    vm.prank(manager);
    pool.publishNav(1e30, 0);

    vm.prank(alice);
    vm.expectRevert("shares below minimum");
    pool.deposit(1_000 ether, alice, quote);

    // without a floor the same deposit goes through for almost nothing
    vm.prank(alice);
    pool.deposit(1_000 ether, alice, 0);
    assertEq(pool.balanceOf(alice), (1_000 ether * 1e18) / 1e30, "dust: 1e9 shares-wei");
  }

  function test_request_rejectsWorthlessAndHonoursMinWithdraw() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
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

  /* ------------------------------ states and pause ------------------------------ */

  /// @dev 限制: subscriptions stop; requests, cancels, settlement and payouts continue.
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
    pool.deposit(MIN_DEPOSIT, alice, 0);
    vm.stopPrank();

    vm.prank(manager);
    pool.openEpoch();
    uint256 a = _request(alice, 5_000 ether);
    vm.prank(alice);
    pool.cancelRedeem(a);
    _request(alice, 10_000 ether);
    _settle(1.0e18);
    _claimEpoch(1);
    assertEq(usdt.balanceOf(alice), 10_000 ether + MIN_DEPOSIT, "payout plus the deposit that was refused");
  }

  function test_pause_freezesFlowsNotTransfers() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    _request(bob, 1_000 ether);
    _settle(1.0e18);
    vm.prank(pauser);
    pool.pause();

    vm.prank(bob);
    pool.transfer(alice, 1 ether); // the share keeps moving
    vm.prank(bob);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    pool.requestRedeem(1 ether);
    uint256[] memory ids = pool.getEpochRequestIds(1);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    pool.claimRedeem(ids);
  }

  function test_closeEpoch_blockedWhilePaused() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    vm.prank(pauser);
    pool.pause();
    vm.prank(manager);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    pool.closeEpoch();
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
    pool.openEpoch();
    _request(bob, 300_000 ether);
    uint256 keep = _request(bob, 100_000 ether);
    assertEq(pool.balanceOf(address(pool)), pool.totalEscrowed());
    assertEq(pool.totalEscrowed(), 400_000 ether);

    vm.prank(bob);
    pool.cancelRedeem(keep);
    assertEq(pool.balanceOf(address(pool)), 300_000 ether);
    assertEq(pool.totalSupply(), 1_000_000 ether, "escrow is still supply");

    _settle(1.0e18);
    assertEq(pool.balanceOf(address(pool)), 0, "burned at settlement");
    assertEq(pool.totalEscrowed(), 0);
    assertEq(pool.totalSupply(), 700_000 ether);
  }

  function test_rescue_cannotMoveEscrowedShares() public {
    _seedPool();
    vm.prank(manager);
    pool.openEpoch();
    _request(bob, 10_000 ether);
    vm.prank(admin);
    vm.expectRevert("cannot rescue own token");
    pool.emergencyWithdraw(address(pool), 10_000 ether, admin);
    assertEq(pool.balanceOf(address(pool)), pool.totalEscrowed());
  }

  /// @dev `type(uint256).max` requests the whole balance at execution.
  function test_request_allSentinel() public {
    _seedPool();
    vm.prank(bob);
    pool.transfer(alice, 2_500 ether);
    vm.prank(manager);
    pool.openEpoch();
    uint256 id = _request(alice, type(uint256).max);
    (, , uint256 shares, , ) = pool.requests(id);
    assertEq(shares, 2_500 ether);
    assertEq(pool.balanceOf(alice), 0);
  }
}
