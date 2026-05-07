// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LisAsterBase } from "./LisAsterBase.t.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { LisAsterDistributor } from "../../src/lisaster/LisAsterDistributor.sol";

contract LisAsterDistributorTest is LisAsterBase {
  /// @dev Pushes `amount` lisAster through the full Astherus -> Vault -> Rewards -> Distributor
  ///      flow and bumps `totalNotified`.
  function _injectNotified(uint256 amount) internal {
    _managerNotify(amount);
    _botDistribute(amount);
  }

  /* ---------------- notifyRewards ---------------- */

  function test_notifyRewards_onlyRewardsAddress() public {
    vm.prank(other);
    vm.expectRevert(bytes("not rewards"));
    distributor.notifyRewards(1 ether);
  }

  function test_notifyRewards_revertsZero() public {
    vm.prank(address(rewards));
    vm.expectRevert(bytes("zero amount"));
    distributor.notifyRewards(0);
  }

  function test_notifyRewards_revertsWithoutAllowance() public {
    // Without prior approval, transferFrom in notifyRewards reverts.
    // Mint lisAster to rewards (bypassing the normal flow) so balance is not the limiter.
    vm.prank(address(vault));
    lisAster.mint(address(rewards), 1 ether);

    vm.prank(address(rewards));
    vm.expectRevert();
    distributor.notifyRewards(1 ether);
  }

  function test_notifyRewards_happyPathBumpsCounter() public {
    _injectNotified(7 ether);
    assertEq(distributor.totalNotified(), 7 ether);
    assertEq(lisAster.balanceOf(address(distributor)), 7 ether);
  }

  /* ---------------- setPendingMerkleRoot / acceptMerkleRoot / revoke / waitingPeriod ---------------- */

  function test_setPendingMerkleRoot_onlyBot() public {
    bytes32 role = distributor.BOT();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    distributor.setPendingMerkleRoot(bytes32(uint256(1)), 0);
  }

  function test_setPendingMerkleRoot_managerCannotStage() public {
    _injectNotified(1 ether);
    bytes32 role = distributor.BOT();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, role));
    vm.prank(manager);
    distributor.setPendingMerkleRoot(_singleLeafRoot(user, 1 ether), 1 ether);
  }

  function test_setPendingMerkleRoot_revertsZeroRoot() public {
    _injectNotified(1 ether);
    vm.prank(bot);
    vm.expectRevert(bytes("zero root"));
    distributor.setPendingMerkleRoot(bytes32(0), 1 ether);
  }

  function test_setPendingMerkleRoot_allocatedMonotonic() public {
    _injectNotified(10 ether);
    _setLiveMerkleRoot(_singleLeafRoot(user, 5 ether), 5 ether);

    vm.prank(bot);
    vm.expectRevert(bytes("allocated decrease"));
    distributor.setPendingMerkleRoot(_singleLeafRoot(user, 4 ether), 4 ether);
  }

  function test_setPendingMerkleRoot_exceedsNotifiedReverts() public {
    _injectNotified(5 ether);
    vm.prank(bot);
    vm.expectRevert(bytes("exceeds notified"));
    distributor.setPendingMerkleRoot(_singleLeafRoot(user, 6 ether), 6 ether);
  }

  function test_setPendingMerkleRoot_overwriteResetsClock() public {
    _injectNotified(10 ether);

    bytes32 r1 = _singleLeafRoot(user, 3 ether);
    vm.prank(bot);
    distributor.setPendingMerkleRoot(r1, 3 ether);
    uint256 firstSet = distributor.lastSetTime();

    vm.warp(firstSet + 30 minutes);
    bytes32 r2 = _singleLeafRoot(user, 5 ether);
    vm.prank(bot);
    distributor.setPendingMerkleRoot(r2, 5 ether);

    assertEq(distributor.pendingMerkleRoot(), r2);
    assertEq(distributor.pendingTotalAllocated(), 5 ether);
    assertEq(distributor.lastSetTime(), block.timestamp);
  }

  function test_acceptMerkleRoot_onlyBot() public {
    _injectNotified(5 ether);
    vm.prank(bot);
    distributor.setPendingMerkleRoot(_singleLeafRoot(user, 5 ether), 5 ether);
    vm.warp(block.timestamp + DISTRIBUTOR_WAITING_PERIOD);

    bytes32 role = distributor.BOT();
    // MANAGER is intentionally not authorized to accept; only BOT can promote.
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, role));
    vm.prank(manager);
    distributor.acceptMerkleRoot();

    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    distributor.acceptMerkleRoot();
  }

  function test_acceptMerkleRoot_revertsBeforeWaitingPeriod() public {
    _injectNotified(5 ether);
    vm.prank(bot);
    distributor.setPendingMerkleRoot(_singleLeafRoot(user, 5 ether), 5 ether);

    // One second short of the wait.
    vm.warp(block.timestamp + DISTRIBUTOR_WAITING_PERIOD - 1);
    vm.prank(bot);
    vm.expectRevert(bytes("waiting period"));
    distributor.acceptMerkleRoot();
  }

  function test_acceptMerkleRoot_revertsNoPending() public {
    vm.prank(bot);
    vm.expectRevert(bytes("no pending root"));
    distributor.acceptMerkleRoot();
  }

  function test_acceptMerkleRoot_promotesAndClearsPending() public {
    _injectNotified(5 ether);
    bytes32 root = _singleLeafRoot(user, 5 ether);

    vm.prank(bot);
    distributor.setPendingMerkleRoot(root, 5 ether);
    vm.warp(block.timestamp + DISTRIBUTOR_WAITING_PERIOD);
    vm.prank(bot);
    distributor.acceptMerkleRoot();

    assertEq(distributor.merkleRoot(), root);
    assertEq(distributor.totalAllocated(), 5 ether);
    assertEq(distributor.merkleRootUpdatedAt(), block.timestamp);
    assertEq(distributor.pendingMerkleRoot(), bytes32(0));
    assertEq(distributor.pendingTotalAllocated(), 0);
    assertEq(distributor.lastSetTime(), 0);
  }

  function test_revokePendingMerkleRoot_byManager() public {
    _injectNotified(5 ether);
    vm.prank(bot);
    distributor.setPendingMerkleRoot(_singleLeafRoot(user, 5 ether), 5 ether);

    vm.prank(manager);
    distributor.revokePendingMerkleRoot();

    assertEq(distributor.pendingMerkleRoot(), bytes32(0));
    assertEq(distributor.pendingTotalAllocated(), 0);
    assertEq(distributor.lastSetTime(), 0);
    // Live root is untouched.
    assertEq(distributor.merkleRoot(), bytes32(0));
  }

  function test_revokePendingMerkleRoot_revertsNoPending() public {
    vm.prank(manager);
    vm.expectRevert(bytes("no pending root"));
    distributor.revokePendingMerkleRoot();
  }

  function test_revokePendingMerkleRoot_onlyManager() public {
    _injectNotified(1 ether);
    vm.prank(bot);
    distributor.setPendingMerkleRoot(_singleLeafRoot(user, 1 ether), 1 ether);

    bytes32 role = distributor.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bot, role));
    vm.prank(bot);
    distributor.revokePendingMerkleRoot();
  }

  function test_changeWaitingPeriod_byAdmin() public {
    vm.prank(admin);
    distributor.changeWaitingPeriod(2 days);
    assertEq(distributor.waitingPeriod(), 2 days);
  }

  function test_changeWaitingPeriod_atMinAccepted() public {
    uint256 minPeriod = distributor.MIN_WAITING_PERIOD();
    vm.prank(admin);
    distributor.changeWaitingPeriod(minPeriod);
    assertEq(distributor.waitingPeriod(), minPeriod);
  }

  function test_changeWaitingPeriod_revertsBelowMin() public {
    uint256 minPeriod = distributor.MIN_WAITING_PERIOD();
    vm.startPrank(admin);
    vm.expectRevert(bytes("waitingPeriod too short"));
    distributor.changeWaitingPeriod(minPeriod - 1);
    vm.expectRevert(bytes("waitingPeriod too short"));
    distributor.changeWaitingPeriod(0);
    vm.stopPrank();
  }

  function test_changeWaitingPeriod_onlyAdmin() public {
    bytes32 role = distributor.DEFAULT_ADMIN_ROLE();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, role));
    vm.prank(manager);
    distributor.changeWaitingPeriod(2 days);
  }

  function test_initialize_revertsBelowMinWaitingPeriod() public {
    LisAsterDistributor freshImpl = new LisAsterDistributor();
    LisAsterDistributor fresh = LisAsterDistributor(address(new ERC1967Proxy(address(freshImpl), "")));
    uint256 minPeriod = freshImpl.MIN_WAITING_PERIOD();

    vm.expectRevert(bytes("waitingPeriod too short"));
    fresh.initialize(admin, manager, bot, pauser, address(lisAster), address(staking), address(rewards), minPeriod - 1);
  }

  /* ---------------- claim ---------------- */

  function test_claim_singleLeaf() public {
    _injectNotified(10 ether);

    bytes32 root = _singleLeafRoot(user, 4 ether);
    bytes32[] memory empty = new bytes32[](0);

    _setLiveMerkleRoot(root, 4 ether);

    distributor.claim(user, 4 ether, empty);

    assertEq(lisAster.balanceOf(user), 4 ether);
    assertEq(distributor.claimed(user), 4 ether);
    assertEq(distributor.totalClaimed(), 4 ether);
  }

  function test_claim_diffOnRootUpdate() public {
    _injectNotified(10 ether);
    bytes32[] memory empty = new bytes32[](0);

    // root 1: user cumulative = 3
    _setLiveMerkleRoot(_singleLeafRoot(user, 3 ether), 3 ether);
    distributor.claim(user, 3 ether, empty);
    assertEq(lisAster.balanceOf(user), 3 ether);

    // root 2: user cumulative = 7 -> only the 4-ether delta is paid.
    _setLiveMerkleRoot(_singleLeafRoot(user, 7 ether), 7 ether);
    distributor.claim(user, 7 ether, empty);
    assertEq(lisAster.balanceOf(user), 7 ether);
    assertEq(distributor.totalClaimed(), 7 ether);
  }

  function test_claim_replayProtection() public {
    _injectNotified(10 ether);
    bytes32[] memory empty = new bytes32[](0);

    _setLiveMerkleRoot(_singleLeafRoot(user, 5 ether), 5 ether);
    distributor.claim(user, 5 ether, empty);

    // Replaying the same cumulativeAmount must revert.
    vm.expectRevert(bytes("nothing to claim"));
    distributor.claim(user, 5 ether, empty);
  }

  function test_claim_revertsInvalidProof() public {
    _injectNotified(10 ether);
    (bytes32 root, , ) = _twoLeafTree(user, 4 ether, other, 6 ether);
    _setLiveMerkleRoot(root, 10 ether);

    bytes32[] memory wrongProof = new bytes32[](1);
    wrongProof[0] = bytes32(uint256(0xdeadbeef));
    vm.expectRevert(bytes("invalid proof"));
    distributor.claim(user, 4 ether, wrongProof);
  }

  function test_claim_twoLeafTree() public {
    _injectNotified(10 ether);
    (bytes32 root, bytes32[] memory p0, bytes32[] memory p1) = _twoLeafTree(user, 4 ether, other, 6 ether);
    _setLiveMerkleRoot(root, 10 ether);

    distributor.claim(user, 4 ether, p0);
    distributor.claim(other, 6 ether, p1);

    assertEq(lisAster.balanceOf(user), 4 ether);
    assertEq(lisAster.balanceOf(other), 6 ether);
    assertEq(distributor.totalClaimed(), 10 ether);
  }

  function test_claimable_consistentWithClaim() public {
    _injectNotified(10 ether);
    (bytes32 root, bytes32[] memory p0, ) = _twoLeafTree(user, 4 ether, other, 6 ether);
    _setLiveMerkleRoot(root, 10 ether);

    uint256 c = distributor.claimable(user, 4 ether, p0);
    assertEq(c, 4 ether);

    distributor.claim(user, 4 ether, p0);

    // After claim, claimable should drop back to 0.
    uint256 c2 = distributor.claimable(user, 4 ether, p0);
    assertEq(c2, 0);
  }

  /* ---------------- claimAndStake ---------------- */

  function test_claimAndStake() public {
    _injectNotified(10 ether);
    bytes32[] memory empty = new bytes32[](0);

    _setLiveMerkleRoot(_singleLeafRoot(user, 4 ether), 4 ether);

    vm.prank(user);
    distributor.claimAndStake(4 ether, empty);

    // user gets a staking position directly instead of holding lisAster.
    assertEq(lisAster.balanceOf(user), 0);
    assertEq(staking.balanceOf(user), 4 ether);
    assertEq(staking.totalSupply(), 4 ether);
    assertEq(lisAster.balanceOf(address(staking)), 4 ether);
  }

  function test_claim_revertsZeroAccount() public {
    _injectNotified(1 ether);
    bytes32[] memory empty = new bytes32[](0);
    vm.expectRevert(bytes("zero account"));
    distributor.claim(address(0), 1 ether, empty);
  }

  function test_claimAndStake_equivalenceWithClaim() public {
    _injectNotified(10 ether);
    (bytes32 root, bytes32[] memory p0, bytes32[] memory p1) = _twoLeafTree(user, 4 ether, other, 6 ether);
    _setLiveMerkleRoot(root, 10 ether);

    distributor.claim(user, 4 ether, p0);
    vm.prank(other);
    distributor.claimAndStake(6 ether, p1);

    // user holds wallet lisAster, other holds a staking position; aggregate accounting matches.
    assertEq(lisAster.balanceOf(user), 4 ether);
    assertEq(staking.balanceOf(other), 6 ether);
    assertEq(distributor.totalClaimed(), 10 ether);
  }

  /* ---------------- emergencyWithdraw ---------------- */

  function test_emergencyWithdraw_byManager() public {
    _injectNotified(5 ether);
    uint256 distBalBefore = lisAster.balanceOf(address(distributor));

    vm.prank(manager);
    distributor.emergencyWithdraw(address(lisAster), 2 ether);

    // Funds always go to the MANAGER caller.
    assertEq(lisAster.balanceOf(manager), 2 ether);
    assertEq(lisAster.balanceOf(address(distributor)), distBalBefore - 2 ether);
    // Accounting is intentionally not adjusted by emergencyWithdraw.
    assertEq(distributor.totalNotified(), 5 ether);
    assertEq(distributor.totalClaimed(), 0);
  }

  function test_emergencyWithdraw_onlyManager() public {
    _injectNotified(1 ether);
    bytes32 role = distributor.MANAGER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    distributor.emergencyWithdraw(address(lisAster), 1 ether);
  }

  function test_emergencyWithdraw_zeroChecks() public {
    vm.startPrank(manager);
    vm.expectRevert(bytes("zero token"));
    distributor.emergencyWithdraw(address(0), 1 ether);
    vm.expectRevert(bytes("zero amount"));
    distributor.emergencyWithdraw(address(lisAster), 0);
    vm.stopPrank();
  }

  /* ---------------- pause ---------------- */

  function test_pause_byPauser() public {
    vm.prank(pauser);
    distributor.pause();
  }

  function test_unpause_byPauser() public {
    vm.prank(pauser);
    distributor.pause();
    vm.prank(pauser);
    distributor.unpause();
  }

  function test_pause_revertsForOther() public {
    bytes32 role = distributor.PAUSER();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
    vm.prank(other);
    distributor.pause();
  }
}
