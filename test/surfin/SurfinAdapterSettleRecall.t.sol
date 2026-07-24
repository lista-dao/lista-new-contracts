// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/surfin/SurfinAdapter.sol";
import "../../src/surfin/FlexEarnPool.sol";
import "../../src/surfin/LockedEarnPool.sol";
import "../../src/mock/MockERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * Regression suite for settleRecall (flex-drain-solution-plan.md §2.5): the weekly
 * multisig recall settlement that replaces repayFromSurfin + bookFee. The manager
 * transfers recalled USDT in and, in one call, resets the Surfin book value, sets
 * the fee earmark, covers the locked queue, and leaves the remainder as buffer.
 */
contract SurfinAdapterSettleRecall is Test {
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

  // set up a matured locked position of `amount`; leaves a 1-batch locked queue.
  // The deposit forwards `amount` to the adapter.
  function _lockedMatured(address who, uint256 amount) internal {
    vm.warp(1_000_000);
    vm.prank(bot);
    locked.setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    usdt.mint(who, amount);
    vm.startPrank(who);
    usdt.approve(address(locked), amount);
    locked.deposit(1, amount, who, false);
    vm.stopPrank();
    vm.warp(block.timestamp + 92 days);
    vm.prank(who);
    locked.requestMaturityWithdraw(0);
  }

  function _managerSettle(
    uint256 recalledAmount,
    uint256 lockedCoverAmount,
    uint256 feeAmount,
    uint256 bookValue
  ) internal {
    usdt.mint(manager, recalledAmount);
    vm.startPrank(manager);
    usdt.approve(address(adapter), recalledAmount);
    adapter.settleRecall(recalledAmount, lockedCoverAmount, feeAmount, bookValue);
    vm.stopPrank();
  }

  function test_settleRecall_reverts_when_recall_insufficient() public {
    // 4k cover + 2k fee = 6k > 5k recalled
    vm.prank(manager);
    vm.expectRevert("recall insufficient");
    adapter.settleRecall(5_000 ether, 4_000 ether, 2_000 ether, 0);
  }

  function test_settleRecall_onlyManager() public {
    vm.prank(bot);
    vm.expectRevert();
    adapter.settleRecall(1 ether, 0, 0, 0);
  }

  function test_settleRecall_happy_covers_locked_sets_fee_book_and_buffer() public {
    _lockedMatured(userA, 10_000 ether); // adapter holds 10k; locked pending 10k, batch1
    uint256 adapterBefore = usdt.balanceOf(address(adapter));
    assertEq(adapterBefore, 10_000 ether, "adapter holds the locked deposit");

    // recall 12k: cover 10k locked, 1k fee, 1k remainder -> buffer; book reset to 500k
    _managerSettle(12_000 ether, 10_000 ether, 1_000 ether, 500_000 ether);

    assertEq(locked.confirmedBatchId(), 1, "locked matured batch confirmed");
    assertEq(adapter.accruedFee(), 1_000 ether, "fee earmarked");
    assertEq(adapter.deployedToSurfin(), 500_000 ether, "deployed book absolutely reset");
    // adapter had 10k, +12k in, -10k pushed to locked pool = 12k remaining
    assertEq(usdt.balanceOf(address(adapter)), 12_000 ether, "cover leaves remainder + prior cash as buffer");
  }

  function test_settleRecall_book_value_can_increase() public {
    // 80% of Surfin interest rolls into principal -> book value goes UP
    _managerSettle(0, 0, 0, 1_000_000 ether);
    assertEq(adapter.deployedToSurfin(), 1_000_000 ether, "book value raised via absolute reset");
  }
}
