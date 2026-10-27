// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";
import "../../src/surfin/BpnEarnPool.sol";
import "../../src/surfin/RenaissNavPool.sol";
import { ISurfinAdapter } from "../../src/surfin/interface/ISurfinAdapter.sol";

/**
 * A pool sends its deposits to `adapter`, but the adapter repays and reserves for
 * whichever pool it lists in the matching slot: FLEX for the flex and BPN pools, LOCKED
 * for the locked and NAV pools. An adapter on the same asset that lists another pool in
 * that slot would take this pool's cash and never pay its requests, so:
 *  - `setAdapter` refuses an adapter that does not list the pool in its slot;
 *  - every deposit (and a locked reinvest) checks the current adapter too, which covers
 *    an adapter set at `initialize` (the deploy scripts pass a placeholder there and
 *    rewire later).
 *
 * The base fixture's `adapter` serves `flex` (FLEX) and `locked` (LOCKED), so it is the
 * "same asset, other pool" adapter for every fresh pool built here.
 */
contract SurfinAdapterSlotTest is SurfinTestBase {
  address placeholder = makeAddr("placeholder");

  /* ---------------------------------- builders ---------------------------------- */

  function _adapterFor(address flexPool_, address lockedPool_) internal returns (SurfinAdapter) {
    return
      SurfinAdapter(
        address(
          new ERC1967Proxy(
            address(new SurfinAdapter(address(usdt))),
            abi.encodeWithSelector(
              SurfinAdapter.initialize.selector,
              admin,
              manager,
              pauser,
              bot,
              flexPool_,
              lockedPool_,
              surfinWallet
            )
          )
        )
      );
  }

  function _freshFlex(address initAdapter) internal returns (FlexEarnPool p) {
    FlexEarnPool impl = new FlexEarnPool();
    p = FlexEarnPool(
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
            initAdapter,
            "Flex2",
            "FLEX2"
          )
        )
      )
    );
    vm.prank(manager);
    p.setCap(type(uint256).max);
  }

  function _freshLocked(address initAdapter) internal returns (LockedEarnPool p) {
    LockedEarnPool impl = new LockedEarnPool();
    p = LockedEarnPool(
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
            initAdapter,
            "Locked2",
            "LOCK2"
          )
        )
      )
    );
    vm.prank(bot);
    p.setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
  }

  function _freshBpn(address initAdapter) internal returns (BpnEarnPool p) {
    BpnEarnPool impl = new BpnEarnPool();
    p = BpnEarnPool(
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
            initAdapter,
            "BPN U Vault",
            "bpnU"
          )
        )
      )
    );
    vm.prank(manager);
    p.setCap(3_000_000 ether);
  }

  function _freshRenaiss(address initAdapter) internal returns (RenaissNavPool p) {
    RenaissNavPool impl = new RenaissNavPool();
    p = RenaissNavPool(
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
            initAdapter,
            "Renaiss LP",
            "rLP",
            1e18
          )
        )
      )
    );
    vm.prank(manager);
    p.setCap(3_000_000 ether);
  }

  /// @dev fund `who` and approve `pool_`; the deposit call itself is left to the test
  function _fund(address who, address pool_, uint256 amount) internal {
    usdt.mint(who, amount);
    vm.prank(who);
    usdt.approve(pool_, amount);
  }

  /* ------------------------------------- BPN ------------------------------------- */

  /// @dev same asset, but the FLEX slot belongs to another pool
  function test_bpn_setAdapter_rejectsAnAdapterWhoseFlexSlotIsAnotherPool() public {
    BpnEarnPool bpn = _freshBpn(placeholder);
    assertEq(adapter.asset(), address(usdt), "the asset check alone would pass");
    assertEq(adapter.flexPool(), address(flex), "the FLEX slot serves another pool");

    vm.prank(admin);
    vm.expectRevert("adapter slot mismatch");
    bpn.setAdapter(address(adapter));
  }

  function test_bpn_setAdapter_rejectsTheLockedSlot() public {
    BpnEarnPool bpn = _freshBpn(placeholder);
    SurfinAdapter wrongSlot = _adapterFor(address(0), address(bpn));

    vm.prank(admin);
    vm.expectRevert("adapter slot mismatch");
    bpn.setAdapter(address(wrongSlot));
  }

  function test_bpn_setAdapter_acceptsItsFlexSlot() public {
    BpnEarnPool bpn = _freshBpn(placeholder);
    SurfinAdapter own = _adapterFor(address(bpn), address(0));

    vm.prank(admin);
    bpn.setAdapter(address(own));
    assertEq(bpn.adapter(), address(own));
  }

  /// @dev an adapter handed to `initialize` never went through `setAdapter`
  function test_bpn_deposit_rejectsAnInitAdapterWhoseFlexSlotIsAnotherPool() public {
    BpnEarnPool bpn = _freshBpn(address(adapter));
    _fund(alice, address(bpn), 1_000 ether);

    // the pool's own check fires before the adapter's deployFromPool would refuse it
    vm.prank(alice);
    vm.expectRevert("adapter slot mismatch");
    bpn.deposit(1_000 ether, alice);
  }

  /// @dev the slot read on the EOA placeholder reverts before any cash moves
  function test_bpn_deposit_failsClosedOnThePlaceholder() public {
    BpnEarnPool bpn = _freshBpn(placeholder);
    _fund(alice, address(bpn), 1_000 ether);

    vm.expectCall(placeholder, abi.encodeCall(ISurfinAdapter.flexPool, ()));
    vm.expectCall(address(usdt), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
    vm.expectRevert(bytes(""));
    vm.prank(alice);
    bpn.deposit(1_000 ether, alice);
  }

  /* ------------------------------------- flex ------------------------------------- */

  function test_flex_setAdapter_rejectsTheLockedSlot() public {
    FlexEarnPool f = _freshFlex(placeholder);
    SurfinAdapter wrongSlot = _adapterFor(address(0), address(f));

    vm.prank(admin);
    vm.expectRevert("adapter slot mismatch");
    f.setAdapter(address(wrongSlot));
  }

  function test_flex_setAdapter_rejectsAnAdapterWhoseFlexSlotIsAnotherPool() public {
    FlexEarnPool f = _freshFlex(placeholder);

    vm.prank(admin);
    vm.expectRevert("adapter slot mismatch");
    f.setAdapter(address(adapter));
  }

  function test_flex_deposit_rejectsAnInitAdapterWhoseFlexSlotIsAnotherPool() public {
    FlexEarnPool f = _freshFlex(address(adapter));
    _fund(alice, address(f), 1_000 ether);

    vm.prank(alice);
    vm.expectRevert("adapter slot mismatch");
    f.deposit(1_000 ether, alice);
  }

  /// @dev before the rewire the placeholder is an EOA; a deposit there used to go through
  function test_flex_deposit_failsClosedOnThePlaceholder() public {
    FlexEarnPool f = _freshFlex(placeholder);
    _fund(alice, address(f), 1_000 ether);

    vm.expectCall(placeholder, abi.encodeCall(ISurfinAdapter.flexPool, ()));
    vm.expectCall(address(usdt), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
    vm.expectRevert(bytes(""));
    vm.prank(alice);
    f.deposit(1_000 ether, alice);
  }

  /* ------------------------------------ locked ------------------------------------ */

  function test_locked_setAdapter_rejectsTheFlexSlot() public {
    LockedEarnPool l = _freshLocked(placeholder);
    SurfinAdapter wrongSlot = _adapterFor(address(l), address(0));

    vm.prank(admin);
    vm.expectRevert("adapter slot mismatch");
    l.setAdapter(address(wrongSlot));
  }

  function test_locked_setAdapter_acceptsItsLockedSlot() public {
    LockedEarnPool l = _freshLocked(placeholder);
    SurfinAdapter own = _adapterFor(address(0), address(l));

    vm.prank(admin);
    l.setAdapter(address(own));
    assertEq(l.adapter(), address(own));
  }

  function test_locked_deposit_rejectsAnInitAdapterWhoseLockedSlotIsAnotherPool() public {
    LockedEarnPool l = _freshLocked(address(adapter));
    _fund(alice, address(l), 1_000 ether);

    vm.prank(alice);
    vm.expectRevert("adapter slot mismatch");
    l.deposit(1, 1_000 ether, alice, false);
  }

  function test_locked_deposit_failsClosedOnThePlaceholder() public {
    LockedEarnPool l = _freshLocked(placeholder);
    _fund(alice, address(l), 1_000 ether);

    vm.expectCall(placeholder, abi.encodeCall(ISurfinAdapter.lockedPool, ()));
    vm.expectCall(address(usdt), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
    vm.expectRevert(bytes(""));
    vm.prank(alice);
    l.deposit(1, 1_000 ether, alice, false);
  }

  /// @dev reinvest returns a funded payout to the adapter, so it is a deposit too; the
  ///      payout can still be claimed
  function test_locked_reinvest_rejectsAnAdapterThatNoLongerListsThePool() public {
    _setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    _depositLocked(alice, 1, 50_000 ether, false);
    vm.warp(block.timestamp + 92 days);
    _setCohort(2, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    vm.prank(alice);
    locked.requestMaturityWithdraw(0);
    _fundAdapter(50_000 ether);
    vm.prank(bot);
    adapter.finishLockedWithdraw(50_000 ether);

    // the adapter is upgraded to one that serves another locked pool
    SlotRewritableAdapter impl = new SlotRewritableAdapter(address(usdt));
    vm.prank(admin);
    adapter.upgradeToAndCall(
      address(impl),
      abi.encodeCall(SlotRewritableAdapter.setLockedPool, (makeAddr("otherLocked")))
    );

    vm.prank(alice);
    vm.expectRevert("adapter slot mismatch");
    locked.reinvest(0, 2, 50_000 ether);

    vm.prank(alice);
    locked.claimWithdraw(alice, 0, 50_000 ether);
    assertEq(usdt.balanceOf(alice), 50_000 ether, "the exit stays open");
  }

  /* ----------------------------------- renaiss ----------------------------------- */

  function test_renaiss_setAdapter_rejectsTheFlexSlot() public {
    RenaissNavPool r = _freshRenaiss(placeholder);
    SurfinAdapter wrongSlot = _adapterFor(address(r), address(0));

    vm.prank(admin);
    vm.expectRevert("adapter slot mismatch");
    r.setAdapter(address(wrongSlot));
  }

  function test_renaiss_setAdapter_acceptsItsLockedSlot() public {
    RenaissNavPool r = _freshRenaiss(placeholder);
    SurfinAdapter own = _adapterFor(address(0), address(r));

    vm.prank(admin);
    r.setAdapter(address(own));
    assertEq(r.adapter(), address(own));
  }

  function test_renaiss_deposit_rejectsAnInitAdapterWhoseLockedSlotIsAnotherPool() public {
    RenaissNavPool r = _freshRenaiss(address(adapter));
    _fund(alice, address(r), 1_000 ether);

    vm.prank(alice);
    vm.expectRevert("adapter slot mismatch");
    r.deposit(1_000 ether, alice, 0);
  }

  function test_renaiss_deposit_failsClosedOnThePlaceholder() public {
    RenaissNavPool r = _freshRenaiss(placeholder);
    _fund(alice, address(r), 1_000 ether);

    vm.expectCall(placeholder, abi.encodeCall(ISurfinAdapter.lockedPool, ()));
    vm.expectCall(address(usdt), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
    vm.expectRevert(bytes(""));
    vm.prank(alice);
    r.deposit(1_000 ether, alice, 0);
  }

  /* --------------------------------- cross-stack --------------------------------- */

  /// @dev a single-product adapter cannot be borrowed by the other product either
  function test_crossStack_bpnAdapterCannotBeWiredIntoANavPool() public {
    BpnEarnPool bpn = _freshBpn(placeholder);
    SurfinAdapter bpnAdapter = _adapterFor(address(bpn), address(0));
    RenaissNavPool r = _freshRenaiss(placeholder);

    vm.prank(admin);
    vm.expectRevert("adapter slot mismatch");
    r.setAdapter(address(bpnAdapter));
  }
}

/// @dev test-only adapter whose locked slot can be rewritten, standing in for an upgrade
contract SlotRewritableAdapter is SurfinAdapter {
  constructor(address _asset) SurfinAdapter(_asset) {}

  function setLockedPool(address _lockedPool) external {
    lockedPool = _lockedPool;
  }
}
