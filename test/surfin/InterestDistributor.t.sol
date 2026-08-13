// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";

/**
 * Test group 3 / module D — InterestDistributor (cumulative Merkle interest).
 *
 * PRD-derived expectations:
 *  - D1 principal/interest are separate; interest is claimed cumulatively — each
 *       claim pays totalAmount - alreadyClaimed, monotonic, no double pay (§4.2)
 *  - D2 root updates are two-step and time-locked (revocable before going live)
 *  - D3 leaves are bound to (chainid, this, selector) so proofs can't be replayed
 *       across chains or contracts (§4.1 dual-chain isolation)
 *
 * Claim math is what is under test here, so the distributor is funded directly;
 * the notifyReward funding path is covered in module C (fundInterest).
 */
contract InterestDistributorTest is SurfinTestBase {
  bytes32[] internal emptyProof;

  /// @dev two-leaf tree with OZ's sorted-pair hashing; returns the root and each proof.
  function _pairTree(
    bytes32 leafA,
    bytes32 leafB
  ) internal pure returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB) {
    root = leafA < leafB ? keccak256(abi.encodePacked(leafA, leafB)) : keccak256(abi.encodePacked(leafB, leafA));
    proofA = new bytes32[](1);
    proofA[0] = leafB;
    proofB = new bytes32[](1);
    proofB[0] = leafA;
  }

  /* ------------ D5: one settled entry must not roll back a batch ------------ */

  /**
   * Claims are permissionless, so anyone can land one entry ahead of a prepared
   * batchClaim. Under the old atomic loop that single already-settled row reverted
   * every other claim in the transaction and the submitter had to rebuild and resubmit
   * while the rest of the users waited.
   */
  function test_D5_batchClaimSkipsAlreadySettledAndPaysTheRest() public {
    usdt.mint(address(distributor), 3_000 ether);
    (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB) = _pairTree(
      _leaf(alice, 1_000 ether),
      _leaf(bob, 2_000 ether)
    );
    _publishRoot(root);

    // someone front-runs the batch with alice's entry
    distributor.claim(alice, 1_000 ether, proofA);
    assertEq(distributor.claimed(alice), 1_000 ether);

    address[] memory accounts = new address[](2);
    uint256[] memory totals = new uint256[](2);
    bytes32[][] memory proofs = new bytes32[][](2);
    (accounts[0], totals[0], proofs[0]) = (alice, 1_000 ether, proofA); // stale
    (accounts[1], totals[1], proofs[1]) = (bob, 2_000 ether, proofB); // still owed

    vm.expectEmit(true, false, false, true, address(distributor));
    emit InterestDistributor.SkipClaim(alice, 1_000 ether, 1_000 ether);

    distributor.batchClaim(accounts, totals, proofs);

    assertEq(usdt.balanceOf(bob), 2_000 ether, "bob was not held hostage by alice's row");
    assertEq(usdt.balanceOf(alice), 1_000 ether, "alice paid exactly once");
  }

  /// @dev only the already-claimed race is tolerated; a bad proof is still a hard error.
  function test_D5_batchClaimStillRevertsOnBadProof() public {
    usdt.mint(address(distributor), 3_000 ether);
    (bytes32 root, , bytes32[] memory proofB) = _pairTree(_leaf(alice, 1_000 ether), _leaf(bob, 2_000 ether));
    _publishRoot(root);

    address[] memory accounts = new address[](1);
    uint256[] memory totals = new uint256[](1);
    bytes32[][] memory proofs = new bytes32[][](1);
    (accounts[0], totals[0], proofs[0]) = (alice, 1_000 ether, proofB); // wrong proof

    vm.expectRevert("Invalid proof");
    distributor.batchClaim(accounts, totals, proofs);
  }

  /* ---------- D6: a staged root keeps the period it was staged under ---------- */

  /// @dev extending the period must not push out a review already running.
  function test_D6_extendingWaitingPeriodDoesNotDelayAStagedRoot() public {
    uint256 staged = block.timestamp;
    vm.prank(bot);
    distributor.setPendingMerkleRoot(_leaf(alice, 1_000 ether));
    assertEq(distributor.pendingActivationTime(), staged + 6 hours, "frozen at the period in force");

    vm.prank(manager);
    distributor.changeWaitingPeriod(7 days); // lands mid-review

    vm.warp(staged + 6 hours);
    vm.prank(bot);
    distributor.acceptMerkleRoot(); // would have needed 7 days under the old live formula
    assertEq(distributor.pendingActivationTime(), 0, "cleared on accept");
  }

  /// @dev and shortening it must not cut a review short either.
  function test_D6_shorteningWaitingPeriodDoesNotRushAStagedRoot() public {
    vm.prank(manager);
    distributor.changeWaitingPeriod(2 days);

    uint256 staged = block.timestamp;
    vm.prank(bot);
    distributor.setPendingMerkleRoot(_leaf(alice, 1_000 ether));
    assertEq(distributor.pendingActivationTime(), staged + 2 days);

    vm.prank(manager);
    distributor.changeWaitingPeriod(6 hours); // shortened mid-review

    vm.warp(staged + 6 hours);
    vm.prank(bot);
    vm.expectRevert("Not ready to accept");
    distributor.acceptMerkleRoot();

    vm.warp(staged + 2 days);
    vm.prank(bot);
    distributor.acceptMerkleRoot(); // the window it was staged under, honoured in full

    // the new period governs the NEXT root
    uint256 staged2 = block.timestamp;
    vm.prank(bot);
    distributor.setPendingMerkleRoot(_leaf(alice, 2_000 ether));
    assertEq(distributor.pendingActivationTime(), staged2 + 6 hours, "new period applies going forward");
  }

  /// @dev revoking clears the frozen deadline along with the root.
  function test_D6_revokeClearsActivationTime() public {
    vm.prank(bot);
    distributor.setPendingMerkleRoot(_leaf(alice, 1_000 ether));
    assertGt(distributor.pendingActivationTime(), 0);

    vm.prank(manager);
    distributor.revokePendingMerkleRoot();
    assertEq(distributor.pendingActivationTime(), 0, "no stale deadline left behind");
  }

  /* ------------------------- D1: cumulative claims ------------------------- */

  function test_D1_cumulativeClaimPaysOnlyTheDelta() public {
    usdt.mint(address(distributor), 2_000 ether);

    _publishRoot(_leaf(alice, 1_000 ether)); // cumulative total 1,000
    distributor.claim(alice, 1_000 ether, emptyProof);
    assertEq(usdt.balanceOf(alice), 1_000 ether, "first claim pays the full 1,000");
    assertEq(distributor.claimed(alice), 1_000 ether);

    _publishRoot(_leaf(alice, 1_500 ether)); // cumulative total 1,500
    distributor.claim(alice, 1_500 ether, emptyProof);
    assertEq(usdt.balanceOf(alice), 1_500 ether, "second claim pays only the 500 delta");
    assertEq(distributor.claimed(alice), 1_500 ether, "claimed is monotonic");
  }

  function test_D1_repeatClaimSameRootReverts() public {
    usdt.mint(address(distributor), 1_000 ether);
    _publishRoot(_leaf(alice, 1_000 ether));

    distributor.claim(alice, 1_000 ether, emptyProof);
    vm.expectRevert("Invalid total amount"); // nothing new to claim
    distributor.claim(alice, 1_000 ether, emptyProof);
  }

  function test_D1_batchClaimTwoLeaves() public {
    usdt.mint(address(distributor), 3_000 ether);

    bytes32 leafA = _leaf(alice, 1_000 ether);
    bytes32 leafB = _leaf(bob, 2_000 ether);
    bytes32 root = leafA < leafB
      ? keccak256(abi.encodePacked(leafA, leafB))
      : keccak256(abi.encodePacked(leafB, leafA));
    _publishRoot(root);

    address[] memory accts = new address[](2);
    uint256[] memory amts = new uint256[](2);
    bytes32[][] memory proofs = new bytes32[][](2);
    accts[0] = alice;
    amts[0] = 1_000 ether;
    proofs[0] = new bytes32[](1);
    proofs[0][0] = leafB;
    accts[1] = bob;
    amts[1] = 2_000 ether;
    proofs[1] = new bytes32[](1);
    proofs[1][0] = leafA;

    distributor.batchClaim(accts, amts, proofs);
    assertEq(usdt.balanceOf(alice), 1_000 ether);
    assertEq(usdt.balanceOf(bob), 2_000 ether);
  }

  function test_D1_invalidProofReverts() public {
    usdt.mint(address(distributor), 1_000 ether);
    _publishRoot(_leaf(alice, 1_000 ether));

    bytes32[] memory badProof = new bytes32[](1);
    badProof[0] = bytes32(uint256(0x1234));
    vm.expectRevert("Invalid proof");
    distributor.claim(alice, 1_000 ether, badProof);
  }

  /* ------------------------ D2: two-step timelock ------------------------ */

  function test_D2_acceptBeforeWaitingPeriodReverts() public {
    vm.prank(bot);
    distributor.setPendingMerkleRoot(_leaf(alice, 1_000 ether));

    vm.prank(bot);
    vm.expectRevert("Not ready to accept");
    distributor.acceptMerkleRoot();
  }

  function test_D2_acceptAfterWaitingPeriodSucceeds() public {
    bytes32 root = _leaf(alice, 1_000 ether);
    vm.prank(bot);
    distributor.setPendingMerkleRoot(root);

    vm.warp(block.timestamp + distributor.waitingPeriod());
    vm.prank(bot);
    distributor.acceptMerkleRoot();
    assertEq(distributor.merkleRoot(), root, "root goes live after the delay");
  }

  function test_D2_setPendingRootOnlyBot() public {
    vm.prank(manager);
    vm.expectRevert();
    distributor.setPendingMerkleRoot(_leaf(alice, 1_000 ether));
  }

  function test_D2_revokePendingRootBlocksAccept() public {
    bytes32 root = _leaf(alice, 1_000 ether);
    vm.prank(bot);
    distributor.setPendingMerkleRoot(root);

    vm.prank(manager);
    distributor.revokePendingMerkleRoot();
    assertEq(distributor.pendingMerkleRoot(), bytes32(0), "pending cleared");

    vm.warp(block.timestamp + distributor.waitingPeriod());
    vm.prank(bot);
    vm.expectRevert("Invalid pending merkle root");
    distributor.acceptMerkleRoot();
  }

  /* ------------------------ D3: replay protection ------------------------ */

  function test_D3_leafFromForeignChainIdReplayFails() public {
    usdt.mint(address(distributor), 1_000 ether);
    // a leaf minted for chainid 999 — claim recomputes with block.chainid, so it won't match
    bytes32 foreignLeaf = keccak256(
      abi.encode(uint256(999), address(distributor), distributor.claim.selector, alice, uint256(1_000 ether))
    );
    _publishRoot(foreignLeaf);

    vm.expectRevert("Invalid proof");
    distributor.claim(alice, 1_000 ether, emptyProof);
  }

  function test_D3_leafBoundToForeignContractReplayFails() public {
    usdt.mint(address(distributor), 1_000 ether);
    // a leaf bound to a different distributor address
    bytes32 foreignLeaf = keccak256(
      abi.encode(block.chainid, address(0xBEEF), distributor.claim.selector, alice, uint256(1_000 ether))
    );
    _publishRoot(foreignLeaf);

    vm.expectRevert("Invalid proof");
    distributor.claim(alice, 1_000 ether, emptyProof);
  }

  /// @dev indexed receiver on the distributor's rescue event.
  ///      This entrypoint has no receiver parameter — it always pays msg.sender — but
  ///      the field is indexed so it filters the same way as the pools and the adapter.
  function test_D4_emergencyWithdrawEventCarriesReceiver() public {
    usdt.mint(address(distributor), 1_000 ether);

    vm.expectEmit(true, true, false, true, address(distributor));
    emit InterestDistributor.EmergencyWithdrawal(manager, address(usdt), 1_000 ether);

    vm.prank(manager);
    distributor.emergencyWithdraw(address(usdt));
    assertEq(usdt.balanceOf(manager), 1_000 ether, "funds reached the logged receiver");
  }
}
