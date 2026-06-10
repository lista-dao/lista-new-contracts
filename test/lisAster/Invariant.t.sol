// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LisAsterBase } from "./LisAsterBase.t.sol";

/// @notice Scenario coverage for the key invariants spelled out in the design doc.
contract InvariantTest is LisAsterBase {
  /* I-1: LisAster.totalSupply == sum of AsterVault.deposit (user deposits only — rewards no
   *      longer re-enter Vault under the ASTER-denominated design). */
  function test_invariant_totalSupplyEqualsDeposits() public {
    _giveAster(user, 3 ether);
    _userDeposit(user, 1 ether, user);
    _userDeposit(user, 2 ether, other);

    _managerNotify(5 ether);

    // Only user deposits (1 + 2 = 3 ether) mint lisAster; the 5 ether reward stays as ASTER
    // in Rewards.
    assertEq(lisAster.totalSupply(), 3 ether);
    assertEq(asterToken.balanceOf(address(astherusVault)), 3 ether);
    assertEq(asterToken.balanceOf(address(rewards)), 5 ether);
  }

  /* I-2: ASTER.balanceOf(Distributor) == totalNotified - totalClaimed. */
  function test_invariant_distributorBalanceMatchesAccounting() public {
    _managerNotify(10 ether);
    _botDistribute(7 ether);

    // notify 7, claim 0.
    assertEq(distributor.totalNotified(), 7 ether);
    assertEq(distributor.totalClaimed(), 0);
    assertEq(asterToken.balanceOf(address(distributor)), 7 ether);

    // Run a claim.
    bytes32[] memory empty = new bytes32[](0);
    _setLiveMerkleRoot(_singleLeafRoot(user, 3 ether), 3 ether);
    distributor.claim(user, 3 ether, empty);

    assertEq(distributor.totalNotified(), 7 ether);
    assertEq(distributor.totalClaimed(), 3 ether);
    assertEq(asterToken.balanceOf(address(distributor)), 4 ether);
    assertEq(asterToken.balanceOf(address(distributor)), distributor.totalNotified() - distributor.totalClaimed());
    assertEq(asterToken.balanceOf(user), 3 ether);
  }

  /* I-3: ASTER.balanceOf(Rewards) == sum(net notifyRewards) - sum(distributeRewards). */
  function test_invariant_rewardsBalance() public {
    _managerNotify(5 ether);
    _managerNotify(3 ether);
    _botDistribute(4 ether);

    assertEq(asterToken.balanceOf(address(rewards)), 4 ether); // 5+3-4
    assertEq(rewards.pendingAster(), 4 ether);
  }

  /* I-4: totalAllocated <= totalNotified -- BOT cannot stage an over-allocated root. */
  function test_invariant_totalAllocatedNotExceedsNotified() public {
    _managerNotify(5 ether);
    _botDistribute(5 ether); // totalNotified = 5

    _setLiveMerkleRoot(_singleLeafRoot(user, 5 ether), 5 ether);
    assertLe(distributor.totalAllocated(), distributor.totalNotified());

    // Over-allocation must revert at stage time.
    _managerNotify(2 ether);
    _botDistribute(2 ether); // totalNotified = 7
    vm.prank(bot);
    vm.expectRevert(bytes("exceeds notified"));
    distributor.setPendingMerkleRoot(_singleLeafRoot(user, 100 ether), 100 ether);
  }

  /* claimed[u] is monotonically non-decreasing. */
  function test_invariant_claimedMonotonic() public {
    _managerNotify(10 ether);
    _botDistribute(10 ether);
    bytes32[] memory empty = new bytes32[](0);

    uint256 prev = distributor.claimed(user);
    _setLiveMerkleRoot(_singleLeafRoot(user, 3 ether), 3 ether);
    distributor.claim(user, 3 ether, empty);
    assertGt(distributor.claimed(user), prev);

    prev = distributor.claimed(user);
    _setLiveMerkleRoot(_singleLeafRoot(user, 8 ether), 8 ether);
    distributor.claim(user, 8 ether, empty);
    assertGt(distributor.claimed(user), prev);
  }
}
