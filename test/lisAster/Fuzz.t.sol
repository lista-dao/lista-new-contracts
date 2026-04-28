// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LisAsterBase } from "./LisAsterBase.t.sol";
import { MerkleVerifier } from "../../src/lisAster/libraries/MerkleVerifier.sol";

/// @notice Covers the "Fuzz" row of the design test matrix:
///         forged Merkle proofs / stale proof against a new root /
///         decreasing cumulativeAmount / claim equivalence with claimAndStake.
contract FuzzTest is LisAsterBase {
  uint256 constant MAX_AMOUNT = 100 ether;

  /// @dev Bumps `totalNotified` to MAX_AMOUNT so subsequent tests are not blocked by the
  ///      `totalAllocated <= totalNotified` check.
  function _seedNotified() internal {
    _managerNotify(MAX_AMOUNT);
    _botDistribute(MAX_AMOUNT);
  }

  /* ---------------- 1:1 deposit / mint invariant ---------------- */

  function testFuzz_depositInvariant(uint256 amount) public {
    amount = bound(amount, vault.minDeposit(), MAX_AMOUNT);
    _giveAster(user, amount);
    _userDeposit(user, amount, user);

    assertEq(lisAster.balanceOf(user), amount, "1:1 mint");
    assertEq(lisAster.totalSupply(), amount, "totalSupply == sum deposits");
    assertEq(asterToken.balanceOf(address(astherusVault)), amount, "ASTER landed in AstherusVault");
    assertEq(asterToken.balanceOf(address(vault)), 0, "vault holds no ASTER");
  }

  /* ---------------- random Merkle proofs are rejected ---------------- */

  /// @notice The only valid claim under the seeded root is (user, 4 ether, []). Any other
  ///         fuzzed (account, cumulative, proof) combination must revert.
  function testFuzz_randomProofRejected(address fuzzAccount, uint256 fuzzCum, bytes32[] calldata fuzzProof) public {
    _seedNotified();
    bytes32 root = _singleLeafRoot(user, 4 ether);
    vm.prank(manager);
    distributor.setMerkleRoot(root, 4 ether);

    // Exclude the only legitimate combination.
    bool legit = (fuzzAccount == user && fuzzCum == 4 ether && fuzzProof.length == 0);
    vm.assume(!legit);
    // Skip the cumulativeAmount == 0 boundary, which short-circuits before Merkle verification.
    vm.assume(fuzzCum > 0);

    vm.expectRevert();
    distributor.claim(fuzzAccount, fuzzCum, fuzzProof);
  }

  /* ---------------- stale proof against a new root ---------------- */

  /// @notice Round 1: user single-leaf root with cumulative = firstCum, user claims it.
  ///         Round 2: root flips to a different leaf for `other`. The user retrying with the
  ///         stale (firstCum, []) must revert (InvalidProof or nothing-to-claim).
  function testFuzz_staleProofAgainstNewRoot(uint256 firstCum, uint256 secondCum) public {
    firstCum = bound(firstCum, 1, MAX_AMOUNT / 2);
    secondCum = bound(secondCum, 1, MAX_AMOUNT / 2);

    _seedNotified();

    bytes32[] memory empty = new bytes32[](0);

    // Round 1.
    vm.prank(manager);
    distributor.setMerkleRoot(_singleLeafRoot(user, firstCum), firstCum);
    distributor.claim(user, firstCum, empty);

    // Round 2: switch root to `other`'s single leaf (totalAllocated must stay monotonic).
    uint256 newAllocated = firstCum + secondCum;
    bytes32 newRoot = _singleLeafRoot(other, secondCum);
    // The declared totalAllocated does not have to equal the tree's actual sum; the contract
    // only checks monotonicity and totalAllocated <= totalNotified.
    vm.prank(manager);
    distributor.setMerkleRoot(newRoot, newAllocated);

    // user retrying with the stale (firstCum, []) -- new root rejects user's leaf.
    vm.expectRevert();
    distributor.claim(user, firstCum, empty);
  }

  /* ---------------- decreasing cumulativeAmount is rejected ---------------- */

  /// @notice If MANAGER mistakenly publishes a smaller cumulative for an account, the existing
  ///         claimed[u] watermark still blocks over-claim via `require(cumulativeAmount > already)`.
  function testFuzz_cumulativeDecreaseReverts(uint256 firstCum, uint256 secondCum) public {
    firstCum = bound(firstCum, 2, MAX_AMOUNT);
    secondCum = bound(secondCum, 0, firstCum - 1);

    _seedNotified();

    bytes32[] memory empty = new bytes32[](0);

    vm.prank(manager);
    distributor.setMerkleRoot(_singleLeafRoot(user, firstCum), firstCum);
    distributor.claim(user, firstCum, empty);

    // Same totalAllocated but the leaf's cumulative is decreased.
    vm.prank(manager);
    distributor.setMerkleRoot(_singleLeafRoot(user, secondCum), firstCum);

    vm.expectRevert(bytes("nothing to claim"));
    distributor.claim(user, secondCum, empty);
  }

  /* ---------------- claim equivalence with claimAndStake ---------------- */

  /// @notice For the same 2-leaf tree, user.claim and other.claimAndStake consume the same
  ///         payable amount and the same totalClaimed delta; only the destination differs
  ///         (wallet vs staking position).
  function testFuzz_claimAndStakeEquivalence(uint256 cum) public {
    cum = bound(cum, 1, MAX_AMOUNT / 2);
    _seedNotified();

    (bytes32 root, bytes32[] memory pUser, bytes32[] memory pOther) = _twoLeafTree(user, cum, other, cum);
    vm.prank(manager);
    distributor.setMerkleRoot(root, 2 * cum);

    uint256 totalSupplyBefore = lisAster.totalSupply();

    distributor.claim(user, cum, pUser);
    distributor.claimAndStake(other, cum, pOther);

    // claim: user holds wallet lisAster.
    assertEq(lisAster.balanceOf(user), cum, "user wallet");
    assertEq(staking.balanceOf(user), 0, "user not staked");

    // claimAndStake: other has a staking position rather than a wallet balance.
    assertEq(lisAster.balanceOf(other), 0, "other not in wallet");
    assertEq(staking.balanceOf(other), cum, "other staked");

    // Both paths consume the same totalClaimed delta (sum equals 2*cum).
    assertEq(distributor.totalClaimed(), 2 * cum, "totalClaimed equivalence");
    // lisAster total supply is unchanged (existing distributor balance is moved, not minted).
    assertEq(lisAster.totalSupply(), totalSupplyBefore, "no mint/burn during claim");
  }

  /* ---------------- multi-round cumulative claimed at once ---------------- */

  /// @notice A user that skips claiming for several rounds can still collect the full delta
  ///         in a single claim against the latest cumulative.
  function testFuzz_skipRounds_singleClaim(uint256 cum1, uint256 cum2, uint256 cum3) public {
    cum1 = bound(cum1, 1, 10 ether);
    cum2 = bound(cum2, cum1 + 1, 30 ether);
    cum3 = bound(cum3, cum2 + 1, 50 ether);

    _seedNotified();

    bytes32[] memory empty = new bytes32[](0);

    vm.startPrank(manager);
    distributor.setMerkleRoot(_singleLeafRoot(user, cum1), cum1);
    distributor.setMerkleRoot(_singleLeafRoot(user, cum2), cum2);
    distributor.setMerkleRoot(_singleLeafRoot(user, cum3), cum3);
    vm.stopPrank();

    // user claims only against the final round's root.
    distributor.claim(user, cum3, empty);

    assertEq(lisAster.balanceOf(user), cum3, "lifetime cum claimed at once");
    assertEq(distributor.claimed(user), cum3);
    assertEq(distributor.totalClaimed(), cum3);
  }
}
