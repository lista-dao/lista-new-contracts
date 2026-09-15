// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/surfin/SurfinAdapter.sol";
import "../../src/surfin/FlexEarnPool.sol";
import "../../src/surfin/LockedEarnPool.sol";
import "../../src/mock/MockERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * Regression suite for the single-pot floor+earmark withdrawal guard
 * (flex-drain-solution-plan.md §2). Proves the two confirmed holes are closed:
 *
 *  - finishFlexWithdraw / finishLockedWithdraw must not push cash below the
 *    protected reserve (accruedFee + 3% hardFloor over both pools' live book).
 *  - CreditFundBase.finishWithdraw must not let withdrawQuota accumulate beyond
 *    the pool's real pending obligation.
 *  - finishLockedWithdraw is MANAGER-gated (weekly settlement), not BOT.
 */
contract SurfinAdapterGuard is Test {
  MockERC20 usdt;
  SurfinAdapter adapter;
  FlexEarnPool flex;
  LockedEarnPool locked;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address bot = makeAddr("bot");
  address surfinWallet = makeAddr("surfinWallet");
  address userA = makeAddr("userA");
  address userB = makeAddr("userB");

  uint256 constant FLOOR_RATE = 3e16; // 3%

  function setUp() public {
    usdt = new MockERC20("USDT", "USDT");

    FlexEarnPool flexImpl = new FlexEarnPool();
    LockedEarnPool lockedImpl = new LockedEarnPool();
    SurfinAdapter adapterImpl = new SurfinAdapter(address(usdt));

    flex = FlexEarnPool(
      address(
        new ERC1967Proxy(
          address(flexImpl),
          abi.encodeWithSelector(
            flexImpl.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(usdt),
            address(this),
            "Flex",
            "FLEX"
          )
        )
      )
    );
    locked = LockedEarnPool(
      address(
        new ERC1967Proxy(
          address(lockedImpl),
          abi.encodeWithSelector(
            lockedImpl.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(usdt),
            address(this),
            "Locked",
            "LOCK"
          )
        )
      )
    );
    adapter = SurfinAdapter(
      address(
        new ERC1967Proxy(
          address(adapterImpl),
          abi.encodeWithSelector(
            adapterImpl.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(flex),
            address(locked),
            surfinWallet
          )
        )
      )
    );

    vm.startPrank(admin);
    flex.setAdapter(address(adapter));
    locked.setAdapter(address(adapter));
    vm.stopPrank();
  }

  function _depositFlex(address who, uint256 amount) internal {
    usdt.mint(who, amount);
    vm.startPrank(who);
    usdt.approve(address(flex), amount);
    flex.deposit(amount, who);
    vm.stopPrank();
  }

  // ---- flex withdraw guard: cannot break the 3% hard floor ----

  function test_finishFlexWithdraw_reverts_when_breaks_floor() public {
    _depositFlex(userA, 100_000 ether); // adapter 100k, totalPrincipal 100k
    // hardFloor = 3% * 100k = 3k -> available = 97k; pushing 97_001 must revert
    vm.prank(bot);
    vm.expectRevert();
    adapter.finishFlexWithdraw(97_001 ether);
  }

  function test_finishFlexWithdraw_ok_down_to_floor() public {
    _depositFlex(userA, 100_000 ether);
    vm.prank(userA);
    flex.requestWithdraw(97_000 ether); // one batch == available
    vm.prank(bot);
    adapter.finishFlexWithdraw(97_000 ether); // exactly to the floor -> ok
    assertEq(usdt.balanceOf(address(adapter)), 3_000 ether, "3% floor preserved");
  }

  // ---- withdrawQuota cap: pushed cash cannot exceed real pending ----

  function test_finishFlexWithdraw_reverts_when_overpush_beyond_pending() public {
    _depositFlex(userA, 100_000 ether);
    vm.prank(userA);
    flex.requestWithdraw(40_000 ether); // pending 40k
    // 90k <= available(97k) passes the reserve guard, but leaves 50k surplus
    // quota > 40k pending -> CreditFundBase cap must revert
    vm.prank(bot);
    vm.expectRevert();
    adapter.finishFlexWithdraw(90_000 ether);
  }

  function test_finishFlexWithdraw_ok_exact_batch() public {
    _depositFlex(userA, 100_000 ether);
    vm.prank(userA);
    flex.requestWithdraw(40_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(40_000 ether); // exact batch, no surplus
    assertEq(flex.confirmedBatchId(), 1, "batch confirmed");
    assertEq(flex.withdrawQuota(), 0, "no surplus quota");
  }

  // ---- finishLockedWithdraw is BOT-gated (recall-late buffer cover) ----

  function test_finishLockedWithdraw_bot_ok() public {
    _depositFlex(userA, 100_000 ether); // adapter 100k, flex principal 100k
    _lockedMaturedRequest(userB, 10_000 ether); // matured locked batch of 10k
    // recall has not landed: BOT covers the matured locked batch out of the buffer
    vm.prank(bot);
    adapter.finishLockedWithdraw(10_000 ether);
    assertEq(locked.confirmedBatchId(), 1, "locked batch covered by bot from buffer");
  }

  function test_finishLockedWithdraw_nonbot_reverts() public {
    _depositFlex(userA, 100_000 ether);
    vm.prank(manager); // manager holds MANAGER, not BOT
    vm.expectRevert();
    adapter.finishLockedWithdraw(1 ether);
  }

  function test_finishLockedWithdraw_reverts_when_breaks_floor() public {
    _depositFlex(userA, 100_000 ether);
    _lockedMaturedRequest(userB, 10_000 ether); // adapter now holds 110k
    // floor = 3% * (100k flex + 10k locked pending) = 3.3k -> available = 106.7k
    vm.prank(bot);
    vm.expectRevert();
    adapter.finishLockedWithdraw(106_701 ether);
  }

  // ---- fundInterest may consume the hard floor, but never the fee earmark ----

  function test_fundInterest_consumes_floor_not_fee() public {
    _depositFlex(userA, 100_000 ether); // adapter 100k, floor = 3k

    // set a 10k fee earmark by settling a recall that only carries fee
    MockDistributor dist = new MockDistributor(address(usdt));
    vm.prank(manager);
    adapter.setInterestDistributor(address(dist));
    usdt.mint(manager, 10_000 ether);
    vm.startPrank(manager);
    usdt.approve(address(adapter), 10_000 ether);
    adapter.settleRecall(10_000 ether, 0, 10_000 ether, 0); // adapter 110k, accruedFee 10k
    vm.stopPrank();

    // funding 100k == bal(110k) - fee(10k): allowed, and it eats through the floor
    vm.prank(manager);
    adapter.fundInterest(100_000 ether);
    assertEq(usdt.balanceOf(address(adapter)), 10_000 ether, "only the fee earmark is left");
    assertEq(adapter.accruedFee(), 10_000 ether, "fee still fully backed");
    assertEq(adapter.instantWithdrawable(), 0, "floor was consumed, nothing withdrawable");

    // one wei more would dip into the fee earmark -> revert
    vm.prank(manager);
    vm.expectRevert("insufficient idle");
    adapter.fundInterest(1);
  }

  // ---- the interest reservation is clamped to what the queue can actually settle ----

  function _wireDistributor() internal returns (MockDistributor dist) {
    dist = new MockDistributor(address(usdt));
    vm.prank(manager);
    adapter.setInterestDistributor(address(dist));
  }

  /// (a) queue >= idle cash — the testnet shape: idle sat on the floor, 1 wei of interest
  ///     reverted, the floor sat unspent. Old ceiling 0, new ceiling = floor.
  function test_fundInterest_queueBeyondIdle_floorStaysReachable() public {
    MockDistributor dist = _wireDistributor();
    _depositFlex(userA, 100_000 ether); // idle 100k, principal 100k, floor 3k
    vm.prank(manager);
    adapter.deployToSurfin(97_000 ether); // idle 3k == floor
    vm.prank(userA);
    flex.requestWithdraw(100_000 ether); // queue 100k; floor base unchanged -> floor 3k

    assertEq(adapter.freeIdle(), 3_000 ether);
    assertEq(adapter.hardFloor(), 3_000 ether, "floor base is principal + unfunded");
    assertEq(adapter.instantWithdrawable(), 0, "the queue can draw nothing from this cash");
    assertEq(adapter.onDemandUnfunded(), 100_000 ether);

    // freeIdle - queue was max(0, 3k - 100k) = 0, so this reverted before the clamp
    vm.prank(manager);
    adapter.fundInterest(3_000 ether);
    assertEq(usdt.balanceOf(address(dist)), 3_000 ether, "the floor is spendable as interest");

    // the documented cost: the floor is gone, so the queue waits for the next recall
    assertEq(adapter.instantWithdrawable(), 0, "queue still waits on the recall");
    vm.prank(manager);
    vm.expectRevert("insufficient idle");
    adapter.fundInterest(1);
  }

  /// (b) floor < queue < idle cash: fundable before, but the floor was out of reach.
  ///     2_000 ether + 1 is one wei past the old ceiling (freeIdle - queue), which is what
  ///     discriminates — at queue == freeIdle - floor exactly the two agree.
  function test_fundInterest_queueBeyondWithdrawable_floorStaysReachable() public {
    MockDistributor dist = _wireDistributor();
    _depositFlex(userA, 100_000 ether); // idle 100k, floor 3k, withdrawable 97k
    vm.prank(userA);
    flex.requestWithdraw(98_000 ether); // 97k < queue 98k < idle 100k

    assertEq(adapter.instantWithdrawable(), 97_000 ether);
    assertEq(adapter.onDemandUnfunded(), 98_000 ether);

    vm.prank(manager);
    adapter.fundInterest(2_000 ether + 1); // one wei past the old ceiling
    assertEq(usdt.balanceOf(address(dist)), 2_000 ether + 1);
  }

  /// (c) queue < withdrawable — clamp inert, full queue still reserved. Guards against
  ///     the change loosening the normal-state ceiling.
  function test_fundInterest_smallQueue_reservationUnchanged() public {
    MockDistributor dist = _wireDistributor();
    _depositFlex(userA, 100_000 ether); // idle 100k, floor 3k, withdrawable 97k
    vm.prank(userA);
    flex.requestWithdraw(50_000 ether); // queue 50k < withdrawable 97k

    vm.prank(manager);
    vm.expectRevert("insufficient idle");
    adapter.fundInterest(50_000 ether + 1); // ceiling is still freeIdle - queue

    vm.prank(manager);
    adapter.fundInterest(50_000 ether);
    assertEq(usdt.balanceOf(address(dist)), 50_000 ether, "full queue still reserved");
    assertEq(adapter.instantWithdrawable(), 47_000 ether, "queue keeps its cash down to the floor");
  }

  /// (d) The residual, pinned deliberately: the ceiling is per-call, so repeated calls
  ///     drain the balance — there is no on-chain total bound once the queue exceeds
  ///     withdrawable. Not an approval of draining; recorded so it is not mistaken for a
  ///     new defect later. Total draw is bounded procedurally (see _availableForInterest).
  function test_fundInterest_ceilingRegenerates_totalBoundIsProcedural() public {
    MockDistributor dist = _wireDistributor();
    _depositFlex(userA, 100_000 ether);
    vm.prank(userA);
    flex.requestWithdraw(98_000 ether); // queue 98k > withdrawable 97k

    uint256 floorAmt = adapter.hardFloor();
    assertEq(floorAmt, 3_000 ether);

    // three successive max-sized fundings each clear the floor amount
    for (uint256 i = 0; i < 3; i++) {
      vm.prank(manager);
      adapter.fundInterest(floorAmt);
    }
    assertEq(usdt.balanceOf(address(dist)), 9_000 ether, "ceiling regenerated each call");
    assertEq(adapter.hardFloor(), floorAmt, "the floor itself never moved");

    // and it keeps regenerating until the cash is gone
    while (adapter.freeIdle() > 0) {
      uint256 c = adapter.freeIdle();
      uint256 avail = adapter.instantWithdrawable();
      uint256 q = adapter.onDemandUnfunded();
      uint256 reserved = q < avail ? q : avail;
      c = c > reserved ? c - reserved : 0;
      if (c == 0) break;
      vm.prank(manager);
      adapter.fundInterest(c);
    }
    assertEq(adapter.freeIdle(), 0, "no on-chain total bound: interest can reach every unit");
    assertEq(adapter.onDemandUnfunded(), 98_000 ether, "the queue is still owed all of it");
  }

  // deposit into a cohort, warp past maturity, request maturity withdraw
  function _lockedMaturedRequest(address who, uint256 amount) internal {
    vm.warp(1_000_000);
    vm.prank(bot);
    locked.setCohort(
      1, // cohortId
      90, // termDays
      block.timestamp + 1 days, // depositDeadline
      block.timestamp + 1 days + 90 days, // maturityTime
      true
    );
    usdt.mint(who, amount);
    vm.startPrank(who);
    usdt.approve(address(locked), amount);
    locked.deposit(1, amount, who, false);
    vm.stopPrank();
    vm.warp(block.timestamp + 1 days + 91 days); // past maturity
    vm.prank(who);
    locked.requestMaturityWithdraw(0);
  }
}

/// minimal IInterestDistributor: pulls the funded amount from the adapter
contract MockDistributor {
  address public asset;

  constructor(address _asset) {
    asset = _asset;
  }

  function token() external view returns (address) {
    return asset;
  }

  function notifyReward(uint256 amount) external {
    IERC20(asset).transferFrom(msg.sender, address(this), amount);
  }
}
