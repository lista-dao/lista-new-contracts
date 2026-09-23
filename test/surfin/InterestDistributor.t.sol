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
}
