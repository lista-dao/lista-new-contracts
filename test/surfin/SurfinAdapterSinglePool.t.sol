// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";

/**
 * Single-product stacks: exactly one adapter pool slot may be address(0), symmetrically.
 *  - flex-only (lockedPool = 0): the BPN shape;
 *  - locked-only (flexPool = 0): the Renaiss shape.
 * Every view stays callable and every money path works for the wired pool; the empty
 * slot's entrypoints revert with a reason instead of calling address(0).
 */
contract SurfinAdapterSinglePoolTest is SurfinTestBase {
  function _adapter(address flexPool, address lockedPool) internal returns (SurfinAdapter a) {
    a = SurfinAdapter(
      address(
        new ERC1967Proxy(
          address(new SurfinAdapter(address(usdt))),
          abi.encodeWithSelector(
            SurfinAdapter.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            flexPool,
            lockedPool,
            surfinWallet
          )
        )
      )
    );
  }

  /// @dev rebuild the fixture around a single-pool adapter (pools are still empty).
  function _rewire(address flexPool, address lockedPool) internal {
    adapter = _adapter(flexPool, lockedPool);
    vm.startPrank(admin);
    if (flexPool != address(0)) flex.setAdapter(address(adapter));
    if (lockedPool != address(0)) locked.setAdapter(address(adapter));
    distributor.grantRole(distributor.FUNDER(), address(adapter));
    vm.stopPrank();
    vm.prank(manager);
    adapter.setInterestDistributor(address(distributor));
  }

  function test_initializeRejectsBothPoolsZero() public {
    address impl = address(new SurfinAdapter(address(usdt)));
    bytes memory init = abi.encodeWithSelector(
      SurfinAdapter.initialize.selector,
      admin,
      manager,
      pauser,
      bot,
      address(0),
      address(0),
      surfinWallet
    );
    vm.expectRevert("both pools are zero address");
    new ERC1967Proxy(impl, init);
  }

  function test_initializeStillChecksTheWiredPoolsAsset() public {
    MockERC20 other = new MockERC20("OTHER", "OTHER");
    FlexEarnPool foreign = FlexEarnPool(
      address(
        new ERC1967Proxy(
          address(new FlexEarnPool()),
          abi.encodeWithSelector(
            FlexEarnPool.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(other),
            address(this),
            "F",
            "F"
          )
        )
      )
    );
    address impl = address(new SurfinAdapter(address(usdt)));
    vm.expectRevert("lockedPool asset mismatch");
    new ERC1967Proxy(
      impl,
      abi.encodeWithSelector(
        SurfinAdapter.initialize.selector,
        admin,
        manager,
        pauser,
        bot,
        address(0),
        address(foreign),
        surfinWallet
      )
    );
  }

  /// @dev BPN shape: the full flex cycle with no locked pool behind the adapter.
  function test_flexOnlyStack() public {
    _rewire(address(flex), address(0));
    _depositFlex(alice, 100_000 ether);

    assertEq(adapter.hardFloor(), 3_000 ether, "floor over the flex book only");
    uint256 deployable = adapter.maxDeployToSurfin();
    assertEq(deployable, 97_000 ether);
    vm.prank(manager);
    adapter.deployToSurfin(deployable);

    vm.prank(alice);
    flex.requestWithdraw(100_000 ether);
    assertEq(adapter.unfundedWithdrawals(), 100_000 ether);

    // weekly recall with no locked cover, then the BOT funds the flex queue
    _settleRecall(100_000 ether, 0, 0, 0);
    vm.prank(bot);
    adapter.finishFlexWithdraw(100_000 ether);
    vm.prank(alice);
    flex.claimWithdraw(alice, 0, 100_000 ether);
    assertEq(usdt.balanceOf(alice), 100_000 ether);

    _fundAdapter(500 ether);
    vm.prank(manager);
    adapter.fundInterest(500 ether);

    // the empty locked slot refuses cover rather than calling address(0)
    _fundAdapter(1_000 ether);
    vm.prank(bot);
    vm.expectRevert("lockedPool not set");
    adapter.finishLockedWithdraw(0);
    usdt.mint(manager, 1_000 ether);
    vm.startPrank(manager);
    usdt.approve(address(adapter), 1_000 ether);
    vm.expectRevert("lockedPool not set");
    adapter.settleRecall(1_000 ether, 1_000 ether, 0, 0);
    vm.stopPrank();
  }

  /// @dev Renaiss shape with the stock locked pool: maturity queue settled by the recall.
  function test_lockedOnlyStack() public {
    _rewire(address(0), address(locked));
    vm.prank(manager);
    adapter.setFloorRate(0);

    vm.warp(1_000_000);
    _setCohort(1, 90, block.timestamp + 1 days, block.timestamp + 91 days, true);
    _depositLocked(alice, 1, 50_000 ether, false);
    vm.prank(manager);
    adapter.deployToSurfin(50_000 ether);

    vm.warp(block.timestamp + 92 days);
    address[] memory users = new address[](1);
    users[0] = alice;
    uint256[] memory ids = new uint256[](1);
    vm.prank(bot);
    locked.batchRequestMaturityWithdraw(users, ids);
    assertEq(adapter.onDemandUnfunded(), 50_000 ether, "locked queue reserved on a locked-only stack");
    assertEq(adapter.unfundedWithdrawals(), 50_000 ether);
    _fundAdapter(1_000 ether);
    assertEq(adapter.maxDeployToSurfin(), 0, "owed principal is not deployable");

    _settleRecall(50_000 ether, 50_000 ether, 0, 0);
    assertEq(adapter.onDemandUnfunded(), 0);
    assertEq(adapter.maxDeployToSurfin(), 1_000 ether, "only the surplus is free");
    vm.prank(alice);
    locked.claimWithdraw(alice, 0, 50_000 ether);
    assertEq(usdt.balanceOf(alice), 50_000 ether);

    vm.prank(bot);
    vm.expectRevert("flexPool not set");
    adapter.finishFlexWithdraw(0);
  }
}
