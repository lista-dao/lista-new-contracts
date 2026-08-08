// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";

/**
 * Test group 3 / module C — SurfinAdapter (fund routing).
 *
 * PRD-derived expectations:
 *  - C1 deploy cap == free idle above the hard floor (§4.6, §14.4)
 *  - C2 settleRecall splits the recall into locked cover + fee + book + buffer (§14.5)
 *  - C3 fundInterest may pierce the hard floor but never the fee earmark (§4.2)
 *  - C4 claimFee only ever moves the earmark to feeReceiver (§12)
 *
 * settleRecall's happy path and insufficiency guard are already covered by
 * SurfinAdapterSettleRecall.t.sol; C2 here adds the fee-only / buffer angle.
 */
contract SurfinAdapterCoreTest is SurfinTestBase {
  /* ------------------------------- C1: deploy ------------------------------- */

  function test_C1_deployCapIsFreeIdleMinusFloor() public {
    _depositFlex(alice, 100_000 ether); // idle 100k, hardFloor 3% = 3k
    assertEq(adapter.maxDeployToSurfin(), 97_000 ether, "deployable == idle - floor");

    vm.prank(manager);
    adapter.deployToSurfin(97_000 ether);
    assertEq(usdt.balanceOf(surfinWallet), 97_000 ether, "sent straight to Surfin wallet");
    assertEq(adapter.deployedToSurfin(), 97_000 ether, "book value tracks the deploy");
    assertEq(adapter.idleBalance(), 3_000 ether, "hard floor retained on the adapter");
  }

  function test_C1_deployOneWeiOverCapReverts() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(manager);
    vm.expectRevert("exceeds deployable");
    adapter.deployToSurfin(97_000 ether + 1);
  }

  function test_C1_deployExcludesFeeEarmarkFromDeployable() public {
    _depositFlex(alice, 100_000 ether);
    _settleRecall(10_000 ether, 0, 10_000 ether, 0); // idle 110k, fee 10k

    // freeIdle = 110k - 10k fee = 100k; floor = 3% * 100k book = 3k -> deployable 97k
    assertEq(adapter.maxDeployToSurfin(), 97_000 ether, "fee earmark excluded from deployable");
  }

  function test_C1_deployOnlyManager() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(bot);
    vm.expectRevert();
    adapter.deployToSurfin(1 ether);
  }

  function test_C1_deployWhenPausedReverts() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(pauser);
    adapter.pause();
    vm.prank(manager);
    vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
    adapter.deployToSurfin(1 ether);
  }

  function test_C1_deployZeroReverts() public {
    vm.prank(manager);
    vm.expectRevert("amount is zero");
    adapter.deployToSurfin(0);
  }

  /* ---------------------------- C2: settleRecall ---------------------------- */

  function test_C2_settleRecallFeeAndBufferWithoutLockedCover() public {
    _depositFlex(alice, 100_000 ether); // adapter 100k
    _settleRecall(5_000 ether, 0, 2_000 ether, 500_000 ether);

    assertEq(adapter.accruedFee(), 2_000 ether, "fee earmarked");
    assertEq(adapter.deployedToSurfin(), 500_000 ether, "book absolutely reset");
    assertEq(adapter.idleBalance(), 105_000 ether, "recall lands as buffer (prior 100k + 5k)");
  }

  function test_C2_settleRecallBookValueCanDropToZero() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(manager);
    adapter.deployToSurfin(90_000 ether);
    assertEq(adapter.deployedToSurfin(), 90_000 ether);

    _settleRecall(90_000 ether, 0, 0, 0); // full recall, book reset to 0
    assertEq(adapter.deployedToSurfin(), 0, "book value reset to zero on full recall");
  }

  /* ---------------------------- C3: fundInterest ---------------------------- */

  function test_C3_fundInterestPiercesFloorAndFundsDistributor() public {
    _depositFlex(alice, 100_000 ether); // idle 100k, floor 3k

    vm.prank(manager);
    adapter.fundInterest(100_000 ether); // consumes the whole balance, floor included

    assertEq(usdt.balanceOf(address(distributor)), 100_000 ether, "interest routed to distributor");
    assertEq(adapter.idleBalance(), 0, "floor may be pierced by interest");
    assertLt(adapter.idleBalance(), adapter.hardFloor(), "confirmed below floor");
  }

  function test_C3_fundInterestNeverPiercesFeeEarmark() public {
    _depositFlex(alice, 100_000 ether);
    _settleRecall(100_000 ether, 0, 100_000 ether, 0); // idle 200k, fee 100k

    // freeIdle above the fee earmark is 100k; one wei more must revert
    vm.prank(manager);
    vm.expectRevert("insufficient idle");
    adapter.fundInterest(100_000 ether + 1);
  }

  function test_C3_fundInterestOnlyManager() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(bot);
    vm.expectRevert();
    adapter.fundInterest(1 ether);
  }

  function test_C3_fundInterestZeroReverts() public {
    _depositFlex(alice, 100_000 ether);
    vm.prank(manager);
    vm.expectRevert("amount is zero");
    adapter.fundInterest(0);
  }

  /* ------------------------------ C4: claimFee ------------------------------ */

  function test_C4_claimFeeMovesEarmarkToFeeReceiver() public {
    _depositFlex(alice, 100_000 ether);
    _settleRecall(10_000 ether, 0, 10_000 ether, 0); // accruedFee 10k

    vm.prank(bot);
    adapter.claimFee(4_000 ether);
    assertEq(usdt.balanceOf(feeReceiver), 4_000 ether, "fee paid to feeReceiver only");
    assertEq(adapter.accruedFee(), 6_000 ether, "earmark decremented");
  }

  function test_C4_claimFeeExceedingAccruedReverts() public {
    _depositFlex(alice, 100_000 ether);
    _settleRecall(10_000 ether, 0, 10_000 ether, 0);
    vm.prank(bot);
    vm.expectRevert("invalid amount");
    adapter.claimFee(10_000 ether + 1);
  }

  function test_C4_claimFeeOnlyBot() public {
    _depositFlex(alice, 100_000 ether);
    _settleRecall(10_000 ether, 0, 10_000 ether, 0);
    vm.prank(alice);
    vm.expectRevert();
    adapter.claimFee(1 ether);
  }
}
