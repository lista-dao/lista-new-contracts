// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";

/**
 * BPN vault on the Surfin template: a flex-only stack (lockedPool = address(0)), the
 * ERC20 flex LP as the 1:1 share, whitelist on for phase 1, cap 3,000,000, floorRate 0
 * since the whole book is forwarded to BPN. Interest is computed off-chain and paid
 * through the cumulative merkle distributor; principal returns through the batch queue.
 *
 * Worked example: 1,000,000 U at 6.75% simple, Actual/360 -> 187.5 U per day.
 *  - 10-01 deposit, accrues from 10-02;
 *  - 11-02 October interest 30 x 187.5 = 5,625 becomes claimable;
 *  - 11-14 (Sat) full withdrawal request, the request day still accrues;
 *  - 11-21 (Sat, first Saturday at least 7 days later) payout of
 *    1,000,000 principal + 14 x 187.5 = 2,625 interest = 1,002,625.
 */
contract BpnFlexVaultTest is SurfinTestBase {
  address anchor = makeAddr("anchor");
  address custodian = makeAddr("custodian");
  address outsider = makeAddr("outsider");

  uint256 constant CAP = 3_000_000 ether;
  uint256 constant PRINCIPAL = 1_000_000 ether;

  uint256 constant OCT_01 = 1790848800; // 2026-10-01 10:00 UTC
  uint256 constant NOV_02 = 1793610000; // 2026-11-02 09:00 UTC
  uint256 constant NOV_05 = 1793880000; // 2026-11-05 12:00 UTC
  uint256 constant NOV_14 = 1794650400; // 2026-11-14 10:00 UTC, Saturday
  uint256 constant NOV_21 = 1795251600; // 2026-11-21 09:00 UTC, Saturday

  function setUp() public override {
    super.setUp();
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
            address(flex),
            address(0), // no locked product
            surfinWallet
          )
        )
      )
    );
    vm.startPrank(admin);
    flex.setAdapter(address(adapter));
    distributor.grantRole(distributor.FUNDER(), address(adapter));
    vm.stopPrank();

    address[] memory anchors = new address[](1);
    anchors[0] = anchor;
    vm.startPrank(manager);
    adapter.setInterestDistributor(address(distributor));
    adapter.setFloorRate(0);
    flex.setCap(CAP);
    flex.setWhitelistEnabled(true);
    flex.setWhitelist(anchors, true);
    vm.stopPrank();
  }

  function _deposit(address who, uint256 amount) internal {
    usdt.mint(who, amount);
    vm.startPrank(who);
    usdt.approve(address(flex), amount);
    flex.deposit(amount, who);
    vm.stopPrank();
  }

  /// @dev BPN pays Lista; the ops Safe sends that interest straight into the distributor.
  function _injectInterest(uint256 amount) internal {
    usdt.mint(manager, amount);
    vm.startPrank(manager);
    usdt.approve(address(adapter), amount);
    adapter.fundInterestFrom(amount);
    vm.stopPrank();
  }

  function test_workedExample_monthlyInterestThenSaturdayPayout() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    assertEq(flex.balanceOf(anchor), PRINCIPAL, "1:1 share");
    vm.prank(manager);
    adapter.deployToSurfin(PRINCIPAL); // floorRate 0: the whole book goes to BPN
    assertEq(usdt.balanceOf(surfinWallet), PRINCIPAL);

    // 11-02: October interest
    vm.warp(NOV_02);
    _injectInterest(5_625 ether);
    _publishRoot(_leaf(anchor, 5_625 ether));
    distributor.claim(anchor, 5_625 ether, new bytes32[](0));
    assertEq(usdt.balanceOf(anchor), 5_625 ether);

    // 11-14: full withdrawal request
    vm.warp(NOV_14);
    vm.prank(anchor);
    flex.requestWithdraw(PRINCIPAL);
    assertEq(flex.totalSupply(), 0);
    assertEq(adapter.onDemandUnfunded(), PRINCIPAL, "queued principal is reserved");

    // 11-21: BPN returns principal + the interest owed to 11-14
    vm.warp(NOV_21);
    _settleRecall(PRINCIPAL, 0, 0, 0);
    vm.prank(bot);
    adapter.finishFlexWithdraw(PRINCIPAL);
    _injectInterest(2_625 ether);
    _publishRoot(_leaf(anchor, 8_250 ether)); // cumulative 5,625 + 2,625

    vm.prank(anchor);
    flex.claimWithdraw(anchor, 0, PRINCIPAL);
    distributor.claim(anchor, 8_250 ether, new bytes32[](0));
    assertEq(usdt.balanceOf(anchor), PRINCIPAL + 8_250 ether, "1,000,000 + 5,625 + 2,625");
    assertEq(adapter.idleBalance(), 0);
    assertEq(usdt.balanceOf(address(distributor)), 0);
  }

  /// @dev a withdrawal waiting for its Saturday holds back idle cash, but not interest the
  ///      partner has already paid in.
  function test_monthlyInterestWhileAWithdrawalIsPending() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);
    vm.prank(manager);
    adapter.deployToSurfin(PRINCIPAL);

    vm.warp(NOV_02 - 3 days); // 10-30: 500,000 requested, payable 11-07
    vm.prank(anchor);
    flex.requestWithdraw(500_000 ether);

    // through idle funds the interest is reserved for the pending withdrawal
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
    assertEq(adapter.idleBalance(), 5_625 ether, "the recalled cash still backs the pending withdrawal");
  }

  function test_fundInterestFrom_rules() public {
    vm.prank(bot);
    vm.expectRevert();
    adapter.fundInterestFrom(1 ether);
    vm.prank(manager);
    vm.expectRevert("amount is zero");
    adapter.fundInterestFrom(0);
  }

  /// @dev shares moved to an address outside the whitelist keep every exit path.
  function test_transfereeOutsideWhitelistExits() public {
    vm.warp(OCT_01);
    _deposit(anchor, PRINCIPAL);

    vm.warp(NOV_05);
    vm.prank(anchor);
    flex.transfer(custodian, 200_000 ether);

    usdt.mint(custodian, 1 ether);
    vm.startPrank(custodian);
    usdt.approve(address(flex), 1 ether);
    vm.expectRevert("not whitelisted");
    flex.deposit(1 ether, custodian);
    flex.requestWithdraw(200_000 ether);
    vm.stopPrank();

    vm.prank(bot);
    adapter.finishFlexWithdraw(200_000 ether); // still idle on the adapter
    vm.prank(custodian);
    flex.claimWithdraw(custodian, 0, 200_000 ether);
    assertEq(usdt.balanceOf(custodian), 200_000 ether + 1 ether);
  }

  /// @dev phase-1 cap: full at 3,000,000; queued withdrawals free capacity again.
  function test_capFullThenRefills() public {
    vm.warp(OCT_01);
    _deposit(anchor, CAP);
    usdt.mint(anchor, 1 ether);
    vm.startPrank(anchor);
    usdt.approve(address(flex), 1 ether);
    vm.expectRevert("exceeds cap");
    flex.deposit(1 ether, anchor);

    flex.requestWithdraw(500_000 ether);
    flex.deposit(1 ether, anchor);
    vm.stopPrank();
    assertEq(flex.totalSupply(), CAP - 500_000 ether + 1 ether);
  }

  /// @dev phase 2 opens to retail by switching the whitelist off; no redeploy.
  function test_phase2_whitelistOff() public {
    vm.prank(manager);
    flex.setWhitelistEnabled(false);
    vm.warp(OCT_01);
    _deposit(outsider, 1_000 ether);
    assertEq(flex.balanceOf(outsider), 1_000 ether);
  }
}
