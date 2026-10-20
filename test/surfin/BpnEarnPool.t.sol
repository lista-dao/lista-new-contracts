// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";
import "../../src/surfin/BpnEarnPool.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * BPN vault on the Surfin template: BpnEarnPool in the adapter's flex slot, no locked
 * pool, whitelist on for phase 1, cap 3,000,000, floorRate 0 since the whole book is
 * forwarded to BPN. Interest is computed off-chain and paid through the cumulative merkle
 * distributor. Redemptions are escrowed at request and settled off-chain-sized, in parts
 * if need be (the weekly cap and pro-rata split are computed off-chain).
 *
 * Worked example: 1,000,000 U at 6.75% simple, Actual/360 -> 187.5 U per day.
 *  - 10-01 deposit, accrues from 10-02;
 *  - 11-02 October interest 30 x 187.5 = 5,625 becomes claimable;
 *  - 11-14 (Sat) full withdrawal request, the request day still accrues;
 *  - 11-21 (Sat, first Saturday at least 7 days later) payout of
 *    1,000,000 principal + 14 x 187.5 = 2,625 interest = 1,002,625.
 */
contract BpnEarnPoolTest is SurfinTestBase {
  BpnEarnPool pool;

  address anchor = makeAddr("anchor");
  address custodian = makeAddr("custodian");
  address outsider = makeAddr("outsider");
  address market = makeAddr("market");

  uint256 constant CAP = 3_000_000 ether;
  uint256 constant PRINCIPAL = 1_000_000 ether;

  uint256 constant OCT_01 = 1790848800; // 2026-10-01 10:00 UTC
  uint256 constant NOV_02 = 1793610000; // 2026-11-02 09:00 UTC
  uint256 constant NOV_05 = 1793880000; // 2026-11-05 12:00 UTC
  uint256 constant NOV_14 = 1794650400; // 2026-11-14 10:00 UTC, Saturday
  uint256 constant NOV_21 = 1795251600; // 2026-11-21 09:00 UTC, Saturday
  uint256 constant NOV_28 = 1795856400; // 2026-11-28 09:00 UTC, Saturday

  function setUp() public override {
    super.setUp();
    BpnEarnPool impl = new BpnEarnPool();
    pool = BpnEarnPool(
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
            "BPN U Vault",
            "bpnU"
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
            address(pool), // the BPN pool rides the flex slot
            address(0), // no locked product
            surfinWallet
          )
        )
      )
    );
    vm.startPrank(admin);
    pool.setAdapter(address(adapter));
    distributor.grantRole(distributor.FUNDER(), address(adapter));
    vm.stopPrank();

    address[] memory anchors = new address[](1);
    anchors[0] = anchor;
    vm.startPrank(manager);
    adapter.setInterestDistributor(address(distributor));
    adapter.setFloorRate(0);
    pool.setWhitelistEnabled(true);
    pool.setWhitelist(anchors, true);
    pool.setCap(CAP);
    vm.stopPrank();
  }

  /* ---------------------------------- helpers ---------------------------------- */

  function _deposit(address who, uint256 amount) internal {
    usdt.mint(who, amount);
    vm.startPrank(who);
    usdt.approve(address(pool), amount);
    pool.deposit(amount, who);
    vm.stopPrank();
  }

  function _allow(address who) internal {
    address[] memory users = new address[](1);
    users[0] = who;
    vm.prank(manager);
    pool.setWhitelist(users, true);
  }

  function _request(address who, uint256 shares) internal returns (uint256 id) {
    vm.prank(who);
    id = pool.requestRedeem(shares);
  }

  /// @dev BPN pays Lista; the ops Safe sends that interest straight into the distributor.
  function _injectInterest(uint256 amount) internal {
    usdt.mint(manager, amount);
    vm.startPrank(manager);
    usdt.approve(address(adapter), amount);
    adapter.fundInterestFrom(amount);
    vm.stopPrank();
  }

  /// @dev BPN returns `amount` of principal: the Safe books it on the adapter, the BOT
  ///      pushes it into the pool.
  function _fundPayout(uint256 amount, uint256 bookAfter) internal {
    _settleRecall(amount, 0, 0, bookAfter);
    vm.prank(bot);
    adapter.finishFlexWithdraw(amount);
  }

  function _settle(uint256[] memory ids, uint256[] memory shares) internal {
    vm.prank(bot);
    pool.settleRedeem(ids, shares);
  }

  function _one(uint256 a) internal pure returns (uint256[] memory r) {
    r = new uint256[](1);
    r[0] = a;
  }

  function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
    r = new uint256[](2);
    (r[0], r[1]) = (a, b);
  }

  function _req(uint256 id) internal view returns (uint256 shares, uint256 pending, uint256 claimable) {
    (, , shares, pending, claimable) = pool.requests(id);
  }

  /* ------------------------------ PRD worked example ------------------------------ */

  function test_workedExample_monthlyInterestThenSaturdayPayout() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    assertEq(pool.balanceOf(anchor), PRINCIPAL, "1:1 share");
    vm.prank(manager);
    adapter.deployToSurfin(PRINCIPAL); // floorRate 0: the whole book goes to BPN
    assertEq(usdt.balanceOf(surfinWallet), PRINCIPAL);

    // 11-02: October interest
    vm.warp(NOV_02);
    _injectInterest(5_625 ether);
    _publishRoot(_leaf(anchor, 5_625 ether));
    distributor.claim(anchor, 5_625 ether, new bytes32[](0));
    assertEq(usdt.balanceOf(anchor), 5_625 ether);

    // 11-14: full withdrawal request, shares escrowed
    vm.warp(NOV_14);
    uint256 id = _request(anchor, PRINCIPAL);
    assertEq(pool.balanceOf(anchor), 0);
    assertEq(pool.balanceOf(address(pool)), PRINCIPAL, "escrowed, not burned");
    assertEq(pool.totalSupply(), PRINCIPAL);
    assertEq(pool.totalPrincipal(), 0, "no longer earning");
    assertEq(adapter.onDemandUnfunded(), PRINCIPAL, "queued principal is reserved");

    // 11-21: BPN returns principal + the interest owed to 11-14
    vm.warp(NOV_21);
    _fundPayout(PRINCIPAL, 0);
    _settle(_one(id), _one(PRINCIPAL));
    assertEq(pool.totalSupply(), 0, "burned at settlement");
    _injectInterest(2_625 ether);
    _publishRoot(_leaf(anchor, 8_250 ether)); // cumulative 5,625 + 2,625

    vm.prank(anchor);
    pool.claimRedeem(_one(id));
    distributor.claim(anchor, 8_250 ether, new bytes32[](0));
    assertEq(usdt.balanceOf(anchor), PRINCIPAL + 8_250 ether, "1,000,000 + 5,625 + 2,625");
    assertEq(adapter.idleBalance(), 0);
    assertEq(usdt.balanceOf(address(pool)), 0);
    assertEq(usdt.balanceOf(address(distributor)), 0);
    assertEq(pool.totalPendingWithdraw(), 0);
    assertEq(pool.totalConfirmedUnclaimed(), 0);
  }

  /* --------------------------- partial, pro-rata payouts --------------------------- */

  /// @dev the weekly cap and the pro-rata split are computed off-chain; the pool pays
  ///      each request in as many parts as it takes and the rest stays queued.
  function test_proRataPartialSettlementRollsOver() public {
    vm.warp(OCT_01);
    _allow(custodian);
    _deposit(anchor, 1_600_000 ether);
    _deposit(custodian, 400_000 ether);
    vm.prank(manager);
    adapter.deployToSurfin(2 * PRINCIPAL);

    vm.warp(NOV_05);
    uint256 a = _request(anchor, 600_000 ether);
    uint256 c = _request(custodian, 400_000 ether);

    // Saturday 1: 25% of 2,000,000 = 500,000, split 60/40
    vm.warp(NOV_14);
    _fundPayout(500_000 ether, 1_500_000 ether);
    vm.expectEmit(true, true, false, true, address(pool));
    emit BpnEarnPool.RedeemSettled(a, anchor, 300_000 ether, 300_000 ether);
    _settle(_two(a, c), _two(300_000 ether, 200_000 ether));

    (uint256 shares, uint256 pending, uint256 claimable) = _req(a);
    assertEq(shares, 600_000 ether);
    assertEq(pending, 300_000 ether, "rolls over");
    assertEq(claimable, 300_000 ether, "partly paid");
    assertEq(pool.totalSupply(), 1_500_000 ether);
    assertEq(pool.totalEscrowed(), 500_000 ether);
    assertEq(adapter.onDemandUnfunded(), 500_000 ether);

    vm.prank(market); // anyone can push the payout
    vm.expectEmit(true, true, false, true, address(pool));
    emit BpnEarnPool.RedeemClaimed(a, anchor, 300_000 ether);
    pool.claimRedeem(_two(a, c));
    assertEq(usdt.balanceOf(anchor), 300_000 ether);
    assertEq(usdt.balanceOf(custodian), 200_000 ether);
    (shares, pending, claimable) = _req(a);
    assertEq(
      abi.encode(shares, pending, claimable),
      abi.encode(600_000 ether, 300_000 ether, 0),
      "part paid, rest queued"
    );

    // Saturday 2: the rest
    vm.warp(NOV_21);
    _fundPayout(500_000 ether, 1_000_000 ether);
    _settle(_two(a, c), _two(300_000 ether, 200_000 ether));
    (shares, pending, claimable) = _req(a);
    assertEq(abi.encode(shares, pending, claimable), abi.encode(600_000 ether, 0, 300_000 ether), "all settled");
    pool.claimRedeem(_two(a, c));
    assertEq(usdt.balanceOf(anchor), 600_000 ether);
    assertEq(usdt.balanceOf(custodian), 400_000 ether);
    (shares, pending, claimable) = _req(a);
    assertEq(abi.encode(shares, pending, claimable), abi.encode(600_000 ether, 0, 0), "claimed");
    assertEq(pool.totalSupply(), 1_000_000 ether, "the anchor's remaining position");
    assertEq(pool.totalEscrowed(), 0);
    assertEq(pool.totalPendingWithdraw(), 0);
    assertEq(adapter.onDemandUnfunded(), 0);
  }

  function test_settle_rules() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    uint256 id = _request(anchor, 100_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(60_000 ether); // still idle on the adapter

    vm.startPrank(bot);
    vm.expectRevert("length mismatch");
    pool.settleRedeem(_one(id), _two(1, 1));
    vm.expectRevert("unknown request");
    pool.settleRedeem(_one(999), _one(1));
    vm.expectRevert("invalid shares");
    pool.settleRedeem(_one(id), _one(0));
    vm.expectRevert("invalid shares");
    pool.settleRedeem(_one(id), _one(100_000 ether + 1));
    vm.expectRevert("exceeds quota");
    pool.settleRedeem(_one(id), _one(60_000 ether + 1));
    vm.expectRevert("invalid shares"); // the same request twice cannot overdraw it
    pool.settleRedeem(_two(id, id), _two(60_000 ether, 40_000 ether + 1));
    vm.stopPrank();

    bytes32 botRole = pool.BOT();
    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, botRole));
    pool.settleRedeem(_one(id), _one(1));

    _settle(_one(id), _one(60_000 ether));
    assertEq(pool.withdrawQuota(), 0);
  }

  /// @dev the adapter can only push cash the unsettled escrow still needs.
  function test_funding_boundedByUnsettledEscrow() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    vm.prank(bot);
    vm.expectRevert("quota exceeds pending");
    adapter.finishFlexWithdraw(1);

    uint256 id = _request(anchor, 100_000 ether);
    vm.startPrank(bot);
    vm.expectRevert("quota exceeds pending");
    adapter.finishFlexWithdraw(100_000 ether + 1);
    adapter.finishFlexWithdraw(100_000 ether);
    pool.settleRedeem(_one(id), _one(100_000 ether));
    vm.expectRevert("quota exceeds pending"); // settled cash licenses no second helping
    adapter.finishFlexWithdraw(1);
    vm.stopPrank();
  }

  /// @dev while a request waits, fresh deposits on the adapter are held for it, so a
  ///      payout can be met from new money instead of a BPN round trip.
  function test_queuedRequestsReserveIdleCash() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    vm.prank(manager);
    adapter.deployToSurfin(PRINCIPAL);

    vm.warp(NOV_05);
    uint256 id = _request(anchor, 300_000 ether);
    _deposit(anchor, 500_000 ether);
    assertEq(adapter.maxDeployToSurfin(), 200_000 ether);
    vm.prank(manager);
    vm.expectRevert("exceeds deployable");
    adapter.deployToSurfin(200_000 ether + 1);

    vm.prank(bot);
    adapter.finishFlexWithdraw(300_000 ether);
    _settle(_one(id), _one(300_000 ether));
    pool.claimRedeem(_one(id));
    assertEq(usdt.balanceOf(anchor), 300_000 ether);
    assertEq(adapter.maxDeployToSurfin(), 200_000 ether);
  }

  /// @dev cash pushed in but not yet settled stays as quota for a later call, and the
  ///      adapter keeps reserving only the escrow it does not cover.
  function test_partialQuotaCarriesOverAndAdapterReservesTheRest() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL); // 1,000,000 idle on the adapter, floorRate 0
    uint256 a = _request(anchor, 300_000 ether);
    uint256 b = _request(anchor, 200_000 ether);
    assertEq(adapter.onDemandUnfunded(), 500_000 ether);
    assertEq(adapter.maxDeployToSurfin(), 500_000 ether);

    vm.prank(bot);
    adapter.finishFlexWithdraw(300_000 ether);
    assertEq(adapter.onDemandUnfunded(), 200_000 ether, "escrow less quota");
    assertEq(adapter.maxDeployToSurfin(), 500_000 ether, "pushing cash frees nothing");
    vm.prank(manager);
    vm.expectRevert("insufficient idle");
    adapter.fundInterest(500_000 ether + 1);

    _settle(_one(a), _one(100_000 ether));
    assertEq(pool.withdrawQuota(), 200_000 ether, "the rest carries over");
    assertEq(pool.totalEscrowed(), 400_000 ether);
    assertEq(adapter.onDemandUnfunded(), 200_000 ether);
    vm.prank(bot);
    vm.expectRevert("quota exceeds pending");
    adapter.finishFlexWithdraw(200_000 ether + 1);

    _settle(_one(a), _one(200_000 ether)); // no new push
    assertEq(pool.withdrawQuota(), 0);

    vm.startPrank(bot); // two pushes, one settlement
    adapter.finishFlexWithdraw(120_000 ether);
    adapter.finishFlexWithdraw(80_000 ether);
    pool.settleRedeem(_one(b), _one(200_000 ether));
    vm.stopPrank();
    pool.claimRedeem(_two(a, b));
    assertEq(usdt.balanceOf(anchor), 500_000 ether);
    assertEq(pool.totalPendingWithdraw(), 0);
    assertEq(usdt.balanceOf(address(pool)), 0);
  }

  /// @dev a pause freezes the allocation of funded cash; the cash itself can still arrive.
  function test_pause_blocksSettlementNotFunding() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    uint256 id = _request(anchor, 100_000 ether);
    vm.prank(pauser);
    pool.pause();

    vm.prank(bot);
    adapter.finishFlexWithdraw(100_000 ether);
    assertEq(pool.withdrawQuota(), 100_000 ether);
    vm.prank(bot);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    pool.settleRedeem(_one(id), _one(100_000 ether));

    vm.prank(manager);
    pool.unpause();
    _settle(_one(id), _one(100_000 ether));
    pool.claimRedeem(_one(id));
    assertEq(usdt.balanceOf(anchor), 100_000 ether);
  }

  function test_finishWithdraw_onlyAdapter() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    _request(anchor, 100_000 ether);
    address[3] memory callers = [bot, manager, admin];
    for (uint256 i = 0; i < 3; i++) {
      vm.prank(callers[i]);
      vm.expectRevert("only adapter can call");
      pool.finishWithdraw(0);
    }
  }

  /// @dev a balance below the minimum exits whole, through max or its exact amount; no
  ///      one can dust it beforehand, since shares do not move between holders.
  function test_redeemAllBelowMinimum() public {
    vm.warp(OCT_01);
    _allow(custodian);
    _deposit(anchor, 500 ether);
    _deposit(custodian, 1_000 ether);
    vm.prank(manager);
    pool.setMinWithdraw(1_000 ether);

    vm.prank(custodian);
    vm.expectRevert("non-transferable");
    pool.transfer(anchor, 1);
    vm.prank(anchor);
    vm.expectRevert("below min withdraw");
    pool.requestRedeem(400 ether);
    vm.prank(anchor);
    uint256 id = pool.requestRedeem(type(uint256).max);
    (, , uint256 shares, , ) = pool.requests(id);
    assertEq(shares, 500 ether);
    assertEq(pool.balanceOf(anchor), 0);
  }

  /// @dev dailyLimit is not applied to requests on this pool.
  function test_dailyLimitNotApplied() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    vm.prank(manager);
    pool.setDailyLimit(100 ether);
    _request(anchor, 500_000 ether);
    assertEq(pool.totalEscrowed(), 500_000 ether);
  }

  /* ------------------------------------ cap ------------------------------------ */

  /// @dev escrowed shares keep counting against the cap until they are settled.
  function test_cap_escrowCountsUntilSettled() public {
    vm.warp(OCT_01);
    _deposit(anchor, CAP);
    uint256 id = _request(anchor, 500_000 ether);

    usdt.mint(anchor, 500_000 ether);
    vm.startPrank(anchor);
    usdt.approve(address(pool), type(uint256).max);
    vm.expectRevert("exceeds cap");
    pool.deposit(1 ether, anchor);
    vm.stopPrank();

    vm.prank(bot);
    adapter.finishFlexWithdraw(200_000 ether);
    _settle(_one(id), _one(200_000 ether));
    vm.startPrank(anchor);
    vm.expectRevert("exceeds cap");
    pool.deposit(200_000 ether + 1, anchor);
    pool.deposit(200_000 ether, anchor);
    vm.stopPrank();
    assertEq(pool.totalSupply(), CAP);
  }

  /* ----------------------------------- claims ----------------------------------- */

  function test_claim_permissionlessIdempotentAndOwnerOnlyPayee() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    uint256 a = _request(anchor, 100_000 ether);
    uint256 b = _request(anchor, 50_000 ether);

    vm.expectRevert("unknown request");
    pool.claimRedeem(_one(999));
    pool.claimRedeem(_two(a, b)); // nothing claimable yet: no-op
    assertEq(usdt.balanceOf(anchor), 0);

    vm.prank(bot);
    adapter.finishFlexWithdraw(100_000 ether);
    _settle(_one(a), _one(100_000 ether));
    vm.prank(market);
    pool.claimRedeem(_two(a, b));
    assertEq(usdt.balanceOf(anchor), 100_000 ether, "paid to the owner");
    assertEq(usdt.balanceOf(market), 0);
    vm.prank(market);
    pool.claimRedeem(_two(a, b));
    assertEq(usdt.balanceOf(anchor), 100_000 ether, "claiming again is a no-op");

    uint256[] memory ids = pool.getUserRequestIds(anchor);
    assertEq(ids.length, 2);
    assertEq(ids[0], a);
    assertEq(ids[1], b);
  }

  /// @dev the template's batch-queue claim has nothing to claim on this pool.
  function test_templateQueueIsInert() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    _request(anchor, 100_000 ether);
    assertEq(pool.getUserWithdrawalRequests(anchor).length, 0);
    assertEq(pool.currentBatchId(), 0);
    vm.prank(anchor);
    vm.expectRevert("invalid index");
    pool.claimWithdraw(anchor, 0, 100_000 ether);
  }

  /// @dev an impaired fund can still be paid out: admin cash becomes settleable quota.
  function test_adminTopUpFundsSettlement() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    vm.prank(manager);
    adapter.deployToSurfin(PRINCIPAL);
    uint256 id = _request(anchor, 100_000 ether);

    usdt.mint(admin, 100_000 ether);
    vm.startPrank(admin);
    usdt.approve(address(pool), 100_000 ether);
    pool.adminTopUp(100_000 ether);
    vm.stopPrank();
    _settle(_one(id), _one(100_000 ether));
    pool.claimRedeem(_one(id));
    assertEq(usdt.balanceOf(anchor), 100_000 ether);
  }

  /* ------------------------------ holders and gates ------------------------------ */

  /// @dev shares are bookkeeping: no transfer or transferFrom between holders, so the
  ///      whitelist cannot be sidestepped and every position stays with its depositor.
  function test_sharesAreNotTransferable() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);

    vm.startPrank(anchor);
    vm.expectRevert("non-transferable");
    pool.transfer(custodian, 1);
    vm.expectRevert("non-transferable");
    pool.transfer(anchor, 1);
    pool.approve(market, PRINCIPAL);
    vm.stopPrank();
    vm.prank(market);
    vm.expectRevert("non-transferable");
    pool.transferFrom(anchor, market, 1);

    assertEq(pool.balanceOf(anchor), PRINCIPAL);
    assertEq(pool.balanceOf(custodian), 0);
    assertEq(pool.balanceOf(market), 0);

    // mint, escrow and burn still work
    uint256 id = _request(anchor, 200_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(200_000 ether);
    _settle(_one(id), _one(200_000 ether));
    pool.claimRedeem(_one(id));
    assertEq(pool.balanceOf(anchor), PRINCIPAL - 200_000 ether);
    assertEq(pool.totalSupply(), PRINCIPAL - 200_000 ether);
    assertEq(usdt.balanceOf(anchor), 200_000 ether);
  }

  function test_request_rules() public {
    vm.warp(OCT_01);
    _deposit(anchor, 1_500 ether);
    vm.startPrank(anchor);
    vm.expectRevert("shares is zero");
    pool.requestRedeem(0);
    vm.expectRevert("insufficient balance");
    pool.requestRedeem(1_500 ether + 1);
    vm.stopPrank();

    vm.prank(manager);
    pool.setMinWithdraw(1_000 ether);
    vm.prank(anchor);
    vm.expectRevert("below min withdraw");
    pool.requestRedeem(600 ether); // would leave 900
    _request(anchor, 1_000 ether);
    _request(anchor, 500 ether); // dust exit: the whole remaining balance
    assertEq(pool.balanceOf(anchor), 0);
  }

  function test_shares_escrowInvariantAndGuards() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    uint256 a = _request(anchor, 300_000 ether);
    _request(anchor, 100_000 ether);
    assertEq(pool.balanceOf(address(pool)), pool.totalEscrowed());

    vm.startPrank(anchor);
    vm.expectRevert("invalid receiver");
    pool.transfer(address(pool), 1);
    vm.expectRevert("non-transferable");
    pool.transfer(address(adapter), 1);
    vm.stopPrank();

    vm.prank(bot);
    adapter.finishFlexWithdraw(120_000 ether);
    _settle(_one(a), _one(120_000 ether));
    assertEq(pool.balanceOf(address(pool)), pool.totalEscrowed());
    assertEq(pool.totalEscrowed(), 280_000 ether);
    assertEq(pool.totalPendingWithdraw(), 400_000 ether, "escrow + settled unclaimed");
    assertEq(pool.totalConfirmedUnclaimed(), 120_000 ether);

    vm.prank(admin);
    vm.expectRevert("cannot rescue own token");
    pool.emergencyWithdraw(address(pool), 1, admin);
  }

  /// @dev restricted state: deposits stop; requests, settlement and claims continue.
  function test_restricted_depositPausedStopsDepositsOnly() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    vm.prank(manager);
    pool.setDepositPaused(true);

    usdt.mint(anchor, 1 ether);
    vm.startPrank(anchor);
    usdt.approve(address(pool), 1 ether);
    vm.expectRevert("deposit paused");
    pool.deposit(1 ether, anchor);
    vm.stopPrank();

    uint256 id = _request(anchor, 100_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(100_000 ether);
    _settle(_one(id), _one(100_000 ether));
    pool.claimRedeem(_one(id));
    assertEq(usdt.balanceOf(anchor), 100_000 ether + 1 ether);
  }

  function test_pause_freezesRequestsAndClaims() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    uint256 id = _request(anchor, 100_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(100_000 ether);
    _settle(_one(id), _one(100_000 ether));
    vm.prank(pauser);
    pool.pause();

    vm.prank(anchor);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    pool.requestRedeem(1 ether);
    uint256[] memory ids = _one(id);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    pool.claimRedeem(ids);
  }

  /* ---------------------------------- interest ---------------------------------- */

  /// @dev a request waiting for its Saturday holds back idle cash, but not interest the
  ///      partner has already paid in.
  function test_monthlyInterestWhileARequestIsPending() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    vm.prank(manager);
    adapter.deployToSurfin(PRINCIPAL);

    vm.warp(NOV_02 - 3 days); // 10-30: 500,000 requested, payable 11-07
    _request(anchor, 500_000 ether);

    // through idle funds the interest is reserved for the pending request
    vm.warp(NOV_02);
    _settleRecall(5_625 ether, 0, 0, PRINCIPAL);
    vm.prank(manager);
    vm.expectRevert("insufficient idle");
    adapter.fundInterest(5_625 ether);

    // paid in directly it is not
    _injectInterest(5_625 ether);
    _publishRoot(_leaf(anchor, 5_625 ether));
    distributor.claim(anchor, 5_625 ether, new bytes32[](0));
    assertEq(usdt.balanceOf(anchor), 5_625 ether);
    assertEq(adapter.idleBalance(), 5_625 ether, "the recalled cash still backs the pending request");
  }

  function test_fundInterestFrom_rules() public {
    vm.prank(bot);
    vm.expectRevert();
    adapter.fundInterestFrom(1 ether);
    vm.prank(manager);
    vm.expectRevert("amount is zero");
    adapter.fundInterestFrom(0);
  }

  /* ----------------------------------- phase 2 ----------------------------------- */

  /// @dev phase 2 opens to retail by switching the whitelist off; no redeploy.
  function test_phase2_whitelistOff() public {
    vm.prank(manager);
    pool.setWhitelistEnabled(false);
    vm.warp(OCT_01);
    _deposit(outsider, 1_000 ether);
    assertEq(pool.balanceOf(outsider), 1_000 ether);
  }

  function test_requestRecord() public {
    vm.warp(NOV_28);
    _deposit(anchor, PRINCIPAL);
    vm.expectEmit(true, true, false, true, address(pool));
    emit BpnEarnPool.RedeemRequested(0, anchor, 10 ether);
    uint256 id = _request(anchor, 10 ether);
    (address owner, uint256 requestedAt, uint256 shares, uint256 pending, uint256 claimable) = pool.requests(id);
    assertEq(owner, anchor);
    assertEq(requestedAt, NOV_28);
    assertEq(shares, 10 ether);
    assertEq(pending, 10 ether);
    assertEq(claimable, 0);
    assertEq(pool.nextRequestId(), 1);
  }
}
