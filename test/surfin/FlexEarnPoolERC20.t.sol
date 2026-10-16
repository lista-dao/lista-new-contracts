// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev 6-decimal asset, to check the LP mirrors the asset's decimals.
contract MockUSDT6Dec is MockERC20 {
  constructor() MockERC20("USDT", "USDT") {}

  function decimals() public pure override returns (uint8) {
    return 6;
  }
}

/**
 * The flex LP as a standard, freely transferable ERC20 (OZ ERC20Upgradeable):
 *  - metadata comes from the pool's own name/symbol and the asset's decimals;
 *  - transfer / approve / transferFrom move the principal claim, ungated by pause,
 *    depositPaused or any whitelist;
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

  /// @dev a transferred LP is a transferred principal claim: the receiver exits with it.
  function test_transferMovesThePrincipalClaim() public {
    _depositFlex(alice, 10_000 ether);
    vm.prank(alice);
    assertTrue(flex.transfer(dave, 4_000 ether));
    assertEq(flex.totalPrincipal(), 10_000 ether, "transfers do not change the book");

    vm.prank(dave);
    flex.requestWithdraw(4_000 ether);
    vm.prank(bot);
    adapter.finishFlexWithdraw(4_000 ether);
    vm.prank(dave);
    flex.claimWithdraw(dave, 0, 4_000 ether);

    assertEq(usdt.balanceOf(dave), 4_000 ether);
    assertEq(flex.balanceOf(alice), 6_000 ether);
    vm.prank(alice);
    vm.expectRevert("insufficient balance");
    flex.requestWithdraw(6_000 ether + 1);
  }

  function test_approveAndTransferFrom() public {
    _depositFlex(alice, 10_000 ether);
    vm.prank(alice);
    flex.approve(bob, 3_000 ether);

    vm.prank(bob);
    flex.transferFrom(alice, dave, 3_000 ether);
    assertEq(flex.balanceOf(dave), 3_000 ether);
    assertEq(flex.allowance(alice, bob), 0);

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
    flex.transferFrom(alice, dave, 1);
  }

  /// @dev pause and depositPaused stop pool flows only; the token keeps moving.
  function test_transfersAreNotPauseGated() public {
    _depositFlex(alice, 10_000 ether);
    vm.prank(manager);
    flex.setDepositPaused(true);
    vm.prank(pauser);
    flex.pause();

    vm.prank(alice);
    flex.transfer(dave, 1_000 ether);
    vm.prank(alice);
    flex.approve(bob, 1_000 ether);
    vm.prank(bob);
    flex.transferFrom(alice, dave, 1_000 ether);
    assertEq(flex.balanceOf(dave), 2_000 ether);

    vm.prank(dave);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    flex.requestWithdraw(2_000 ether);
  }
}
