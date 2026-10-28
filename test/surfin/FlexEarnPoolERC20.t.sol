// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";

/// @dev 6-decimal asset, to check the LP mirrors the asset's decimals.
contract MockUSDT6Dec is MockERC20 {
  constructor() MockERC20("USDT", "USDT") {}

  function decimals() public pure override returns (uint8) {
    return 6;
  }
}

/**
 * The flex LP as an ERC20 (OZ ERC20Upgradeable) that only moves by mint and burn:
 *  - metadata comes from the pool's own name/symbol and the asset's decimals;
 *  - transfer / transferFrom between holders revert;
 *  - requestWithdraw still burns at request time.
 */
contract FlexEarnPoolERC20Test is SurfinTestBase {
  address dave = makeAddr("dave");

  function test_metadataFromPoolAndAsset() public view {
    assertEq(flex.name(), "Flex");
    assertEq(flex.symbol(), "FLEX");
    assertEq(flex.decimals(), 18);
    // the locked pool keeps its getters on the shared base
    assertEq(locked.name(), "Locked");
    assertEq(locked.symbol(), "LOCK");
    assertEq(locked.decimals(), 18);
  }

  function test_decimalsMirrorA6DecAsset() public {
    MockUSDT6Dec usdt6 = new MockUSDT6Dec();
    FlexEarnPool p = FlexEarnPool(
      address(
        new ERC1967Proxy(
          address(new FlexEarnPool()),
          abi.encodeWithSelector(
            FlexEarnPool.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(usdt6),
            address(this),
            "Flex6",
            "F6"
          )
        )
      )
    );
    assertEq(p.decimals(), 6);
  }

  function test_depositMintsAndRequestBurnsWithTransferEvents() public {
    usdt.mint(alice, 1_000 ether);
    vm.startPrank(alice);
    usdt.approve(address(flex), 1_000 ether);
    vm.expectEmit(true, true, false, true, address(flex));
    emit IERC20.Transfer(address(0), alice, 1_000 ether);
    flex.deposit(1_000 ether, alice);

    vm.expectEmit(true, true, false, true, address(flex));
    emit IERC20.Transfer(alice, address(0), 400 ether);
    flex.requestWithdraw(400 ether);
    vm.stopPrank();

    assertEq(flex.balanceOf(alice), 600 ether);
    assertEq(flex.totalSupply(), 600 ether);
    assertEq(flex.totalPrincipal(), 600 ether);
  }

  /// @dev the LP cannot change hands, whatever the pause state
  function test_lpIsNotTransferable() public {
    _depositFlex(alice, 10_000 ether);
    vm.startPrank(alice);
    vm.expectRevert("non-transferable");
    flex.transfer(dave, 1);
    vm.expectRevert("non-transferable");
    flex.transfer(alice, 1);
    flex.approve(bob, 1_000 ether);
    vm.stopPrank();

    vm.startPrank(bob);
    vm.expectRevert("non-transferable");
    flex.transferFrom(alice, dave, 1);
    vm.expectRevert("non-transferable");
    flex.transferFrom(alice, alice, 1);
    vm.stopPrank();
    assertEq(flex.allowance(alice, bob), 1_000 ether);

    vm.prank(pauser);
    flex.pause();
    vm.prank(alice);
    vm.expectRevert("non-transferable");
    flex.transfer(dave, 1);
    assertEq(flex.balanceOf(alice), 10_000 ether);
    assertEq(flex.balanceOf(dave), 0);
  }

  /// @dev `type(uint256).max` withdraws the whole balance at execution.
  function test_requestWithdrawAll() public {
    _depositFlex(alice, 1_500 ether);
    vm.prank(alice);
    flex.requestWithdraw(type(uint256).max);
    assertEq(flex.balanceOf(alice), 0);
    assertEq(flex.totalPendingWithdraw(), 1_500 ether);
  }
}
