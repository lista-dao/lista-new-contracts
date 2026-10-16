// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";

/**
 * Deposit gates on the ERC20 flex pool:
 *  - `cap` bounds the outstanding supply and is 0 (closed) on a fresh pool;
 *  - the optional whitelist gates deposits only (depositor and receiver), never transfers,
 *    payout requests or claims;
 *  - LP can never be parked on the pool or the adapter.
 */
contract FlexEarnPoolDepositGateTest is SurfinTestBase {
  address outsider = makeAddr("outsider");

  function _fund(address who, uint256 amount) internal {
    usdt.mint(who, amount);
    vm.prank(who);
    usdt.approve(address(flex), type(uint256).max);
  }

  function _list(address user) internal {
    address[] memory users = new address[](1);
    users[0] = user;
    vm.prank(manager);
    flex.setWhitelist(users, true);
  }

  /* ------------------------------------ cap ------------------------------------ */

  function test_cap_freshPoolIsClosed() public {
    FlexEarnPool fresh = FlexEarnPool(
      address(
        new ERC1967Proxy(
          address(new FlexEarnPool()),
          abi.encodeWithSelector(
            FlexEarnPool.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(usdt),
            address(adapter),
            "F",
            "F"
          )
        )
      )
    );
    assertEq(fresh.cap(), 0);
    usdt.mint(alice, 1 ether);
    vm.startPrank(alice);
    usdt.approve(address(fresh), 1 ether);
    vm.expectRevert("exceeds cap");
    fresh.deposit(1 ether, alice);
    vm.stopPrank();
  }

  /// @dev the cap counts outstanding LP, so burned (requested) principal frees capacity.
  function test_cap_onOutstandingSupply() public {
    vm.prank(manager);
    flex.setCap(1_000 ether);
    _fund(alice, 2_000 ether);

    vm.startPrank(alice);
    flex.deposit(1_000 ether, alice);
    vm.expectRevert("exceeds cap");
    flex.deposit(1, alice);

    flex.requestWithdraw(400 ether);
    flex.deposit(400 ether, alice);
    vm.expectRevert("exceeds cap");
    flex.deposit(1, alice);
    vm.stopPrank();
    assertEq(flex.totalSupply(), 1_000 ether);
  }

  function test_setCap_rules() public {
    vm.prank(alice);
    vm.expectRevert();
    flex.setCap(1);

    vm.startPrank(manager);
    vm.expectRevert("same cap");
    flex.setCap(type(uint256).max);
    vm.expectEmit(false, false, false, true, address(flex));
    emit CreditFundSharePool.SetCap(3_000_000 ether);
    flex.setCap(3_000_000 ether);
    vm.stopPrank();
    assertEq(flex.cap(), 3_000_000 ether);
  }

  /* --------------------------------- whitelist --------------------------------- */

  function test_whitelistOffByDefault() public {
    assertFalse(flex.whitelistEnabled());
    _fund(outsider, 100 ether);
    vm.prank(outsider);
    flex.deposit(100 ether, outsider);
    assertEq(flex.balanceOf(outsider), 100 ether);
  }

  function test_whitelist_gatesDepositorAndReceiver() public {
    vm.prank(manager);
    flex.setWhitelistEnabled(true);
    _list(alice);
    _fund(alice, 300 ether);
    _fund(outsider, 100 ether);

    vm.prank(alice);
    flex.deposit(100 ether, alice);

    vm.prank(outsider);
    vm.expectRevert("not whitelisted");
    flex.deposit(100 ether, outsider);

    vm.prank(alice);
    vm.expectRevert("not whitelisted");
    flex.deposit(100 ether, outsider); // listed depositor, unlisted receiver

    vm.prank(outsider);
    vm.expectRevert("not whitelisted");
    flex.deposit(100 ether, alice); // unlisted depositor, listed receiver
  }

  /// @dev removal and transfers never touch exits: a delisted or never-listed holder exits normally.
  function test_whitelist_onlyGatesDeposits() public {
    vm.prank(manager);
    flex.setWhitelistEnabled(true);
    _list(alice);
    _fund(alice, 1_000 ether);
    vm.prank(alice);
    flex.deposit(1_000 ether, alice);

    address[] memory users = new address[](1);
    users[0] = alice;
    vm.prank(manager);
    flex.setWhitelist(users, false);
    assertFalse(flex.isWhitelisted(alice));

    vm.prank(alice);
    flex.transfer(outsider, 400 ether); // to an address that was never listed
    vm.prank(alice);
    flex.requestWithdraw(600 ether);
    vm.prank(outsider);
    flex.requestWithdraw(400 ether);

    vm.prank(manager);
    adapter.setFloorRate(0);
    vm.prank(bot);
    adapter.finishFlexWithdraw(1_000 ether);

    vm.prank(alice);
    flex.claimWithdraw(alice, 0, 600 ether);
    vm.prank(outsider);
    flex.claimWithdraw(outsider, 0, 400 ether);
    assertEq(usdt.balanceOf(outsider), 400 ether);
  }

  function test_whitelist_setters() public {
    address[] memory users = new address[](2);
    (users[0], users[1]) = (alice, bob);

    vm.prank(alice);
    vm.expectRevert();
    flex.setWhitelist(users, true);
    vm.prank(alice);
    vm.expectRevert();
    flex.setWhitelistEnabled(true);

    vm.startPrank(manager);
    vm.expectRevert("same status");
    flex.setWhitelistEnabled(false);
    vm.expectEmit(true, false, false, true, address(flex));
    emit CreditFundSharePool.WhitelistChanged(alice, true);
    flex.setWhitelist(users, true);
    vm.expectRevert("same status");
    flex.setWhitelist(users, true);

    address[] memory zero = new address[](1);
    vm.expectRevert("user is zero address");
    flex.setWhitelist(zero, true);
    vm.stopPrank();

    address[] memory listed = flex.getWhitelist();
    assertEq(listed.length, 2);
    assertTrue(flex.isWhitelisted(bob));
  }

  /* ------------------------------ receiver guard ------------------------------ */

  function test_lpCannotBeParkedOnPoolOrAdapter() public {
    _fund(alice, 1_000 ether);

    vm.startPrank(alice);
    vm.expectRevert("invalid receiver");
    flex.deposit(100 ether, address(flex));
    vm.expectRevert("invalid receiver");
    flex.deposit(100 ether, address(adapter));

    flex.deposit(500 ether, alice);
    vm.expectRevert("invalid receiver");
    flex.transfer(address(flex), 1);
    vm.expectRevert("invalid receiver");
    flex.transfer(address(adapter), 1);
    flex.approve(bob, 1);
    vm.stopPrank();

    vm.prank(bob);
    vm.expectRevert("invalid receiver");
    flex.transferFrom(alice, address(flex), 1);
  }
}
