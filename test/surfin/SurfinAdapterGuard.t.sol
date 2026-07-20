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
            flexImpl.initialize.selector, admin, manager, pauser, bot, address(usdt), address(this), "Flex", "FLEX"
          )
        )
      )
    );
    locked = LockedEarnPool(
      address(
        new ERC1967Proxy(
          address(lockedImpl),
          abi.encodeWithSelector(
            lockedImpl.initialize.selector, admin, manager, pauser, bot, address(usdt), address(this), "Locked", "LOCK"
          )
        )
      )
    );
    adapter = SurfinAdapter(
      address(
        new ERC1967Proxy(
          address(adapterImpl),
          abi.encodeWithSelector(
            adapterImpl.initialize.selector, admin, manager, pauser, bot, address(flex), address(locked), surfinWallet
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

  // partial funding followed by a cancellation must NOT wedge batch confirmation:
  // the surplus-quota check runs only on funding pushes (amount > 0), so a 0-amount
  // tick still confirms the shrunk batch and the remaining user can claim.
  function test_finishFlexWithdraw_cancel_after_partial_fund_does_not_wedge() public {
    _depositFlex(userA, 100_000 ether);
    vm.startPrank(userA);
    flex.requestWithdraw(40_000 ether); // req idx0, batch1
    flex.requestWithdraw(60_000 ether); // req idx1, batch1 (total 100k)
    vm.stopPrank();

    vm.prank(bot);
    adapter.finishFlexWithdraw(70_000 ether); // partial fund: quota 70k < batch 100k
    assertEq(flex.confirmedBatchId(), 0, "not yet confirmed");

    vm.prank(userA);
    flex.cancelWithdraw(1); // cancel the 60k request -> batch1 now 40k, quota still 70k

    // a 0-amount tick confirms the 40k batch despite the 30k surplus quota (no revert)
    vm.prank(bot);
    adapter.finishFlexWithdraw(0);
    assertEq(flex.confirmedBatchId(), 1, "batch confirmed by tick, no DoS");
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
    vm.prank(bot);
    adapter.fundInterest(100_000 ether);
    assertEq(usdt.balanceOf(address(adapter)), 10_000 ether, "only the fee earmark is left");
    assertEq(adapter.accruedFee(), 10_000 ether, "fee still fully backed");
    assertEq(adapter.instantWithdrawable(), 0, "floor was consumed, nothing withdrawable");

    // one wei more would dip into the fee earmark -> revert
    vm.prank(bot);
    vm.expectRevert("insufficient idle");
    adapter.fundInterest(1);
  }

  // deposit into a cohort, warp past maturity, request maturity withdraw
  function _lockedMaturedRequest(address who, uint256 amount) internal {
    vm.warp(1_000_000);
    vm.prank(manager);
    locked.setCohort(
      1, // cohortId
      90, // termDays
      114e15, // baseQuote 11.4%
      block.timestamp + 1 days, // depositDeadline
      block.timestamp + 1 days, // interestStartTime
      block.timestamp + 1 days + 90 days, // maturityTime
      true
    );
    usdt.mint(who, amount);
    vm.startPrank(who);
    usdt.approve(address(locked), amount);
    locked.deposit(1, amount, who);
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

  function tokens(address) external pure returns (bool) {
    return true;
  }

  function notifyReward(address token, uint256 amount) external {
    IERC20(token).transferFrom(msg.sender, address(this), amount);
  }
}
