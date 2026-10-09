// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { XAUECardVault } from "../../src/xaueCard/XAUECardVault.sol";
import { MockXAUT } from "../slisXAUE/mocks/MockXAUT.sol";
import { FeeOnTransferXAUT } from "./mocks/FeeOnTransferXAUT.sol";
import { ERC1271Signer } from "./mocks/ERC1271Signer.sol";

contract XAUECardVaultTest is Test {
  XAUECardVault vault;
  MockXAUT xaut;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address bot = makeAddr("bot");
  address receiver = makeAddr("xaueReceiver");
  address alice = makeAddr("alice");
  address bob = makeAddr("bob");

  uint256 signerPk = 0xA11CE;
  address signerAddr;

  uint256 constant CAP = 10_000e6;
  uint256 constant MIN_DEPOSIT = 1e6;

  // cached so expectRevert arguments never consume a prank with a view call
  bytes32 constant ADMIN_ROLE = bytes32(0);
  bytes32 constant MANAGER_ROLE = keccak256("MANAGER");
  bytes32 constant BOT_ROLE = keccak256("BOT");

  function setUp() public {
    xaut = new MockXAUT();
    signerAddr = vm.addr(signerPk);
    vault = _deploy(address(xaut));
    xaut.mint(alice, 1_000_000e6);
    xaut.mint(bob, 1_000_000e6);
  }

  /* HELPERS */

  function _deploy(address assetAddr) internal returns (XAUECardVault) {
    XAUECardVault impl = new XAUECardVault();
    return
      XAUECardVault(
        address(
          new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
              XAUECardVault.initialize,
              (admin, manager, pauser, bot, assetAddr, receiver, signerAddr, CAP, MIN_DEPOSIT)
            )
          )
        )
      );
  }

  function _repay(uint256 amount) internal {
    // XAUE returns XAUt for withdrawal requests with a plain transfer to the vault
    xaut.mint(address(vault), amount);
  }

  function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return abi.encodePacked(r, s, v);
  }

  function _redeemSig(address user, uint256 amount, uint256 deadline) internal view returns (bytes memory) {
    return _sig(signerPk, vault.hashRedeem(user, amount, vault.nonces(user), deadline));
  }

  function _liquidateSig(address user, uint256 amount, bytes32 id) internal view returns (bytes memory) {
    return _sig(signerPk, vault.hashLiquidate(user, amount, id));
  }

  function _deposit(address user, uint256 amount) internal {
    vm.startPrank(user);
    xaut.approve(address(vault), amount);
    vault.deposit(amount);
    vm.stopPrank();
  }

  function _requestRedeem(address user, uint256 amount) internal returns (uint256 idx) {
    uint256 deadline = block.timestamp + 30 minutes;
    bytes memory sig = _redeemSig(user, amount, deadline);
    vm.prank(user);
    vault.requestRedeem(amount, deadline, sig);
    return vault.getUserWithdrawalRequestCount(user) - 1;
  }

  function _markClaimable(address user, uint256 nonce) internal {
    address[] memory users = new address[](1);
    uint256[] memory nonces_ = new uint256[](1);
    users[0] = user;
    nonces_[0] = nonce;
    vm.prank(bot);
    vault.markClaimable(users, nonces_);
  }

  function _liquidate(address user, uint256 amount, bytes32 id) internal {
    XAUECardVault.LiquidationItem[] memory items = new XAUECardVault.LiquidationItem[](1);
    items[0] = XAUECardVault.LiquidationItem({ user: user, amount: amount, liquidationId: id });
    bytes[] memory sigs = new bytes[](1);
    sigs[0] = _liquidateSig(user, amount, id);
    vm.prank(bot);
    vault.liquidate(items, sigs);
  }

  function _request(address user, uint256 idx) internal view returns (XAUECardVault.WithdrawalRequest memory) {
    return vault.getUserWithdrawalRequests(user)[idx];
  }

  function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
    return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
  }

  // ─── Credential ───────────────────────────────────────────────────────────

  function test_credential_metadata_and_non_transferable() public {
    assertEq(vault.decimals(), 6);
    assertEq(vault.symbol(), "CreditXAUT");
    _deposit(alice, 10e6);

    vm.startPrank(alice);
    vm.expectRevert(bytes("not transferable"));
    vault.transfer(bob, 1e6);
    vm.expectRevert(bytes("not transferable"));
    vault.approve(bob, 1e6);
    vm.expectRevert(bytes("not transferable"));
    vault.transferFrom(alice, bob, 1e6);
    vm.stopPrank();

    assertEq(vault.balanceOf(alice), 10e6);
    assertEq(vault.balanceOf(bob), 0);
  }

  // ─── Deposit ──────────────────────────────────────────────────────────────

  function test_deposit_forwards_to_receiver_and_vault_holds_nothing() public {
    _deposit(alice, 100e6);
    assertEq(vault.balanceOf(alice), 100e6);
    assertEq(vault.totalSupply(), 100e6);
    assertEq(xaut.balanceOf(receiver), 100e6);
    assertEq(xaut.balanceOf(address(vault)), 0);
    assertEq(vault.withdrawQuota(), 0);
  }

  function test_deposit_zero_reverts() public {
    vm.prank(alice);
    vm.expectRevert(bytes("amount is zero"));
    vault.deposit(0);
  }

  function test_deposit_below_min_reverts() public {
    vm.startPrank(alice);
    xaut.approve(address(vault), MIN_DEPOSIT);
    vm.expectRevert(bytes("below min deposit"));
    vault.deposit(MIN_DEPOSIT - 1);
    vm.stopPrank();
  }

  function test_deposit_exceeds_cap_reverts() public {
    _deposit(alice, CAP);
    vm.startPrank(bob);
    xaut.approve(address(vault), 1e6);
    vm.expectRevert(bytes("exceeds cap"));
    vault.deposit(1e6);
    vm.stopPrank();
  }

  function test_cap_reopens_after_burn() public {
    _deposit(alice, CAP);
    _requestRedeem(alice, 500e6);
    _deposit(bob, 500e6);
    assertEq(vault.totalSupply(), CAP);
  }

  function test_deposit_fee_on_transfer_mints_received() public {
    FeeOnTransferXAUT fee = new FeeOnTransferXAUT(100, makeAddr("tetherFees")); // 1%
    XAUECardVault v = _deploy(address(fee));
    fee.mint(alice, 1_000e6);

    vm.startPrank(alice);
    fee.approve(address(v), 100e6);
    v.deposit(100e6);
    vm.stopPrank();

    assertEq(v.balanceOf(alice), 99e6, "mint what arrived, not what was sent");
    assertEq(fee.balanceOf(receiver), 99e6);
  }

  function test_deposit_from_receiver_itself_reverts() public {
    // receiver's balance does not change when it deposits to itself: nothing to mint against
    vm.prank(admin);
    vault.setReceiver(alice);
    vm.startPrank(alice);
    xaut.approve(address(vault), 10e6);
    vm.expectRevert(bytes("nothing received"));
    vault.deposit(10e6);
    vm.stopPrank();
  }

  function test_deposit_paused_by_action() public {
    vm.prank(pauser);
    vault.pauseAction(XAUECardVault.Action.Deposit);

    vm.startPrank(alice);
    xaut.approve(address(vault), 10e6);
    vm.expectRevert(bytes("action paused"));
    vault.deposit(10e6);
    vm.stopPrank();

    // PAUSER cannot lift it, MANAGER can
    vm.prank(pauser);
    vm.expectRevert(_unauthorized(pauser, MANAGER_ROLE));
    vault.unpauseAction(XAUECardVault.Action.Deposit);
    vm.prank(manager);
    vault.unpauseAction(XAUECardVault.Action.Deposit);
    _deposit(alice, 10e6);
    assertEq(vault.balanceOf(alice), 10e6);
  }

  function test_deposit_paused_globally() public {
    vm.prank(pauser);
    vault.pause();
    vm.startPrank(alice);
    xaut.approve(address(vault), 10e6);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vault.deposit(10e6);
    vm.stopPrank();
    vm.prank(manager);
    vault.unpause();
    _deposit(alice, 10e6);
  }

  // ─── Redeem request ───────────────────────────────────────────────────────

  function test_requestRedeem_burns_and_queues_request() public {
    _deposit(alice, 100e6);
    uint256 idx = _requestRedeem(alice, 40e6);

    assertEq(idx, 0);
    assertEq(vault.balanceOf(alice), 60e6);
    assertEq(vault.totalPendingRedeem(), 40e6);
    assertEq(vault.nonces(alice), 1);
    XAUECardVault.WithdrawalRequest memory req = _request(alice, idx);
    assertEq(req.withdrawTime, uint40(block.timestamp));
    assertEq(req.amount, 40e6);
    assertEq(req.nonce, 0);
    assertFalse(req.claimable);
    assertEq(vault.getUserWithdrawalRequestCount(alice), 1);
  }

  function test_requestRedeem_rejects_wrong_signer() public {
    _deposit(alice, 100e6);
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sig(0xBAD, vault.hashRedeem(alice, 10e6, 0, deadline));
    vm.prank(alice);
    vm.expectRevert(bytes("invalid signature"));
    vault.requestRedeem(10e6, deadline, sig);
  }

  function test_requestRedeem_rejects_other_user_submitting() public {
    _deposit(alice, 100e6);
    _deposit(bob, 100e6);
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _redeemSig(alice, 10e6, deadline);
    vm.prank(bob);
    vm.expectRevert(bytes("invalid signature"));
    vault.requestRedeem(10e6, deadline, sig);
  }

  function test_requestRedeem_rejects_amount_mismatch() public {
    _deposit(alice, 100e6);
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _redeemSig(alice, 10e6, deadline);
    vm.prank(alice);
    vm.expectRevert(bytes("invalid signature"));
    vault.requestRedeem(20e6, deadline, sig);
  }

  function test_requestRedeem_rejects_expired() public {
    _deposit(alice, 100e6);
    uint256 deadline = block.timestamp + 30 minutes;
    bytes memory sig = _redeemSig(alice, 10e6, deadline);
    vm.warp(deadline + 1);
    vm.prank(alice);
    vm.expectRevert(bytes("signature expired"));
    vault.requestRedeem(10e6, deadline, sig);
  }

  function test_requestRedeem_rejects_nonce_reuse() public {
    _deposit(alice, 100e6);
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _redeemSig(alice, 10e6, deadline);
    vm.startPrank(alice);
    vault.requestRedeem(10e6, deadline, sig);
    vm.expectRevert(bytes("invalid signature"));
    vault.requestRedeem(10e6, deadline, sig);
    vm.stopPrank();
  }

  function test_requestRedeem_rejects_insufficient_balance() public {
    _deposit(alice, 10e6);
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _redeemSig(alice, 11e6, deadline);
    vm.prank(alice);
    vm.expectRevert(bytes("insufficient balance"));
    vault.requestRedeem(11e6, deadline, sig);
  }

  function test_requestRedeem_accepts_erc1271_signer() public {
    ERC1271Signer contractSigner = new ERC1271Signer(signerAddr);
    vm.prank(admin);
    vault.setSigner(address(contractSigner));

    _deposit(alice, 100e6);
    _requestRedeem(alice, 10e6); // signed by signerPk, verified through the contract
    assertEq(vault.balanceOf(alice), 90e6);
  }

  function test_setSigner_invalidates_old_signatures() public {
    _deposit(alice, 100e6);
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _redeemSig(alice, 10e6, deadline);

    vm.prank(admin);
    vault.setSigner(makeAddr("newSigner"));

    vm.prank(alice);
    vm.expectRevert(bytes("invalid signature"));
    vault.requestRedeem(10e6, deadline, sig);
  }

  function test_requestRedeem_paused_by_action() public {
    _deposit(alice, 100e6);
    vm.prank(pauser);
    vault.pauseAction(XAUECardVault.Action.Redeem);
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _redeemSig(alice, 10e6, deadline);
    vm.prank(alice);
    vm.expectRevert(bytes("action paused"));
    vault.requestRedeem(10e6, deadline, sig);
  }

  // ─── markClaimable ────────────────────────────────────────────────────────

  function test_markClaimable_requires_repayment() public {
    _deposit(alice, 100e6);
    uint256 idx = _requestRedeem(alice, 40e6);

    address[] memory users = new address[](1);
    uint256[] memory nonces_ = new uint256[](1);
    users[0] = alice;
    nonces_[0] = 0;

    vm.prank(bot);
    vm.expectRevert(bytes("insufficient repayment"));
    vault.markClaimable(users, nonces_);

    _repay(39e6);
    vm.prank(bot);
    vm.expectRevert(bytes("insufficient repayment"));
    vault.markClaimable(users, nonces_);

    _repay(1e6);
    _markClaimable(alice, 0);
    assertTrue(_request(alice, idx).claimable);
    assertEq(vault.reservedForClaims(), 40e6);
    assertEq(vault.totalPendingRedeem(), 0);
    assertEq(vault.withdrawQuota(), 0);
  }

  function test_markClaimable_rejects_unknown_nonce_double_mark_role_and_lengths() public {
    _deposit(alice, 100e6);
    _requestRedeem(alice, 40e6); // nonce 0
    _repay(40e6);

    address[] memory users = new address[](1);
    uint256[] memory nonces_ = new uint256[](1);
    users[0] = alice;
    nonces_[0] = 7; // never issued
    vm.prank(bot);
    vm.expectRevert(bytes("request not found"));
    vault.markClaimable(users, nonces_);

    nonces_[0] = 0;
    _markClaimable(alice, 0);
    vm.prank(bot);
    vm.expectRevert(bytes("already claimable"));
    vault.markClaimable(users, nonces_);

    vm.prank(manager);
    vm.expectRevert(_unauthorized(manager, BOT_ROLE));
    vault.markClaimable(users, nonces_);

    uint256[] memory empty = new uint256[](0);
    vm.prank(bot);
    vm.expectRevert(bytes("length mismatch"));
    vault.markClaimable(users, empty);
  }

  function test_markClaimable_by_nonce_survives_swap_pop() public {
    // BOT decides to mark B (nonce 1) while alice claims A: B slides from idx 1 to idx 0,
    // and the nonce-addressed mark still lands on B.
    _deposit(alice, 100e6);
    uint256 a = _requestRedeem(alice, 10e6); // nonce 0
    _requestRedeem(alice, 20e6); // nonce 1
    _repay(30e6);
    _markClaimable(alice, 0);

    vm.prank(alice);
    vault.claimWithdraw(a);
    assertEq(vault.getUserWithdrawalRequestCount(alice), 1);
    assertEq(_request(alice, 0).nonce, 1, "B moved into slot 0");

    _markClaimable(alice, 1);
    assertTrue(_request(alice, 0).claimable);
    assertEq(vault.reservedForClaims(), 20e6);
  }

  function test_markClaimable_distinguishes_same_amount_same_block_requests() public {
    _deposit(alice, 100e6);
    _requestRedeem(alice, 10e6); // nonce 0
    _requestRedeem(alice, 10e6); // nonce 1, same block, same amount
    _repay(10e6);

    _markClaimable(alice, 1);
    assertFalse(_request(alice, 0).claimable, "first request untouched");
    assertTrue(_request(alice, 1).claimable, "exactly the second one marked");
  }

  function test_markClaimable_works_while_paused_and_batches_users() public {
    _deposit(alice, 100e6);
    _deposit(bob, 100e6);
    uint256 a = _requestRedeem(alice, 40e6);
    uint256 b = _requestRedeem(bob, 10e6);
    _repay(50e6);
    vm.prank(pauser);
    vault.pause();
    vm.prank(pauser);
    vault.pauseAction(XAUECardVault.Action.Claim);

    address[] memory users = new address[](2);
    uint256[] memory nonces_ = new uint256[](2);
    users[0] = alice;
    users[1] = bob;
    nonces_[0] = 0;
    nonces_[1] = 0;
    vm.prank(bot);
    vault.markClaimable(users, nonces_);
    assertTrue(_request(alice, a).claimable);
    assertTrue(_request(bob, b).claimable);
    assertEq(vault.reservedForClaims(), 50e6);
  }

  // ─── Claim ────────────────────────────────────────────────────────────────

  function test_claimWithdraw_transfers_and_removes_request() public {
    _deposit(alice, 100e6);
    uint256 idx = _requestRedeem(alice, 40e6);
    _repay(40e6);
    _markClaimable(alice, 0);

    uint256 before = xaut.balanceOf(alice);
    vm.prank(alice);
    vault.claimWithdraw(idx);
    assertEq(xaut.balanceOf(alice) - before, 40e6);
    assertEq(vault.reservedForClaims(), 0);
    assertEq(vault.getUserWithdrawalRequestCount(alice), 0, "claimed request removed");
    assertEq(xaut.balanceOf(address(vault)), 0);
    assertEq(xaut.balanceOf(receiver), 100e6, "deposits were never in the vault");
  }

  function test_claimWithdraw_rejects_pending_bad_index_and_other_user() public {
    _deposit(alice, 100e6);
    uint256 idx = _requestRedeem(alice, 40e6);

    vm.prank(alice);
    vm.expectRevert(bytes("not claimable yet"));
    vault.claimWithdraw(idx);

    vm.prank(alice);
    vm.expectRevert(bytes("invalid index"));
    vault.claimWithdraw(idx + 1);

    _repay(40e6);
    _markClaimable(alice, 0);

    // bob has no requests: the same index is out of range for him
    vm.prank(bob);
    vm.expectRevert(bytes("invalid index"));
    vault.claimWithdraw(idx);

    vm.prank(alice);
    vault.claimWithdraw(idx);
    vm.prank(alice);
    vm.expectRevert(bytes("invalid index"));
    vault.claimWithdraw(idx);
  }

  function test_claimWithdraw_swap_and_pop_keeps_other_requests() public {
    _deposit(alice, 100e6);
    uint256 a = _requestRedeem(alice, 10e6);
    _requestRedeem(alice, 20e6);
    _requestRedeem(alice, 30e6);
    _repay(60e6);
    _markClaimable(alice, 0);

    vm.prank(alice);
    vault.claimWithdraw(a);

    XAUECardVault.WithdrawalRequest[] memory reqs = vault.getUserWithdrawalRequests(alice);
    assertEq(reqs.length, 2);
    assertEq(reqs[0].amount, 30e6, "last request moved into the claimed slot");
    assertEq(reqs[1].amount, 20e6);
    assertFalse(reqs[0].claimable);
    assertEq(vault.totalPendingRedeem(), 50e6);
    assertEq(vault.reservedForClaims(), 0);
  }

  function test_claimWithdraw_paused_by_action() public {
    _deposit(alice, 100e6);
    uint256 idx = _requestRedeem(alice, 40e6);
    _repay(40e6);
    _markClaimable(alice, 0);
    vm.prank(pauser);
    vault.pauseAction(XAUECardVault.Action.Claim);
    vm.prank(alice);
    vm.expectRevert(bytes("action paused"));
    vault.claimWithdraw(idx);
  }

  // ─── Liquidate ────────────────────────────────────────────────────────────────

  function test_liquidate_burns_and_marks_id_without_moving_cash() public {
    _deposit(alice, 100e6);
    bytes32 id = keccak256("LIQ-2026-09-28-001");
    _liquidate(alice, 30e6, id);
    assertEq(vault.balanceOf(alice), 70e6);
    assertTrue(vault.usedLiquidationIds(id));
    assertEq(xaut.balanceOf(receiver), 100e6);
    assertEq(xaut.balanceOf(address(vault)), 0);
  }

  function test_liquidate_rejects_replay_bad_sig_balance_role_and_lengths() public {
    _deposit(alice, 100e6);
    bytes32 id = keccak256("LIQ-1");
    _liquidate(alice, 30e6, id);

    XAUECardVault.LiquidationItem[] memory items = new XAUECardVault.LiquidationItem[](1);
    items[0] = XAUECardVault.LiquidationItem({ user: alice, amount: 30e6, liquidationId: id });
    bytes[] memory sigs = new bytes[](1);
    sigs[0] = _liquidateSig(alice, 30e6, id);

    vm.prank(bot);
    vm.expectRevert(bytes("liquidation already executed"));
    vault.liquidate(items, sigs);

    items[0].liquidationId = keccak256("LIQ-2");
    vm.prank(bot);
    vm.expectRevert(bytes("invalid signature")); // sig was for LIQ-1
    vault.liquidate(items, sigs);

    items[0].amount = 71e6;
    sigs[0] = _liquidateSig(alice, 71e6, items[0].liquidationId);
    vm.prank(bot);
    vm.expectRevert(bytes("insufficient balance"));
    vault.liquidate(items, sigs);

    items[0].amount = 70e6;
    sigs[0] = _liquidateSig(alice, 70e6, items[0].liquidationId);
    vm.prank(manager);
    vm.expectRevert(_unauthorized(manager, BOT_ROLE));
    vault.liquidate(items, sigs);

    bytes[] memory empty = new bytes[](0);
    vm.prank(bot);
    vm.expectRevert(bytes("length mismatch"));
    vault.liquidate(items, empty);
  }

  function test_liquidate_batches_rows_and_ignores_action_pauses() public {
    _deposit(alice, 100e6);
    _deposit(bob, 50e6);
    // per-action flags are for user entry points; an automated liquidation ignores them
    vm.startPrank(pauser);
    vault.pauseAction(XAUECardVault.Action.Deposit);
    vault.pauseAction(XAUECardVault.Action.Redeem);
    vault.pauseAction(XAUECardVault.Action.Claim);
    vm.stopPrank();

    XAUECardVault.LiquidationItem[] memory items = new XAUECardVault.LiquidationItem[](2);
    items[0] = XAUECardVault.LiquidationItem({ user: alice, amount: 10e6, liquidationId: keccak256("a") });
    items[1] = XAUECardVault.LiquidationItem({ user: bob, amount: 5e6, liquidationId: keccak256("b") });
    bytes[] memory sigs = new bytes[](2);
    sigs[0] = _liquidateSig(alice, 10e6, keccak256("a"));
    sigs[1] = _liquidateSig(bob, 5e6, keccak256("b"));
    vm.prank(bot);
    vault.liquidate(items, sigs);

    assertEq(vault.balanceOf(alice), 90e6);
    assertEq(vault.balanceOf(bob), 45e6);
  }

  function test_liquidate_blocked_by_global_pause() public {
    // the global pause is the brake on the automated burn path
    _deposit(alice, 100e6);
    XAUECardVault.LiquidationItem[] memory items = new XAUECardVault.LiquidationItem[](1);
    items[0] = XAUECardVault.LiquidationItem({ user: alice, amount: 10e6, liquidationId: keccak256("a") });
    bytes[] memory sigs = new bytes[](1);
    sigs[0] = _liquidateSig(alice, 10e6, keccak256("a"));

    vm.prank(pauser);
    vault.pause();
    vm.prank(bot);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    vault.liquidate(items, sigs);

    vm.prank(manager);
    vault.unpause();
    vm.prank(bot);
    vault.liquidate(items, sigs);
    assertEq(vault.balanceOf(alice), 90e6);
  }

  // ─── Admin ────────────────────────────────────────────────────────────────

  function test_withdrawExcess_bounded_by_withdrawQuota() public {
    _deposit(alice, 100e6);
    uint256 idx = _requestRedeem(alice, 40e6);
    _repay(50e6);
    _markClaimable(alice, 0);
    assertEq(vault.withdrawQuota(), 10e6);

    vm.prank(admin);
    vm.expectRevert(bytes("exceeds withdraw quota"));
    vault.withdrawExcess(11e6, admin);

    vm.prank(admin);
    vault.withdrawExcess(10e6, admin);
    assertEq(xaut.balanceOf(admin), 10e6);
    assertEq(vault.withdrawQuota(), 0);

    vm.prank(manager);
    vm.expectRevert(_unauthorized(manager, ADMIN_ROLE));
    vault.withdrawExcess(1, manager);

    vm.prank(alice);
    vault.claimWithdraw(idx);
    assertEq(xaut.balanceOf(address(vault)), 0);
  }

  function test_rescueToken_rejects_asset() public {
    vm.prank(manager);
    vm.expectRevert(bytes("cannot rescue asset"));
    vault.rescueToken(address(xaut), 1, manager);

    MockXAUT other = new MockXAUT();
    other.mint(address(vault), 5e6);
    vm.prank(manager);
    vault.rescueToken(address(other), 5e6, manager);
    assertEq(other.balanceOf(manager), 5e6);
  }

  function test_setReceiver_admin_only_and_applies_to_next_deposit() public {
    vm.prank(manager);
    vm.expectRevert(_unauthorized(manager, ADMIN_ROLE));
    vault.setReceiver(bob);

    _deposit(alice, 10e6);

    vm.startPrank(admin);
    vm.expectRevert(bytes("receiver is zero"));
    vault.setReceiver(address(0));
    vm.expectRevert(bytes("same receiver"));
    vault.setReceiver(receiver);
    address newReceiver = makeAddr("newReceiver");
    vault.setReceiver(newReceiver);
    vm.stopPrank();

    _deposit(alice, 5e6);
    assertEq(xaut.balanceOf(receiver), 10e6, "old receiver keeps what it got");
    assertEq(xaut.balanceOf(newReceiver), 5e6);
  }

  function test_setter_roles() public {
    vm.prank(manager);
    vm.expectRevert(_unauthorized(manager, ADMIN_ROLE));
    vault.setSigner(bob);

    vm.prank(admin);
    vm.expectRevert(_unauthorized(admin, MANAGER_ROLE));
    vault.setCap(1);

    vm.startPrank(manager);
    vault.setCap(1);
    vm.expectRevert(bytes("same cap"));
    vault.setCap(1);
    vault.setMinDeposit(2);
    vm.expectRevert(bytes("same minDeposit"));
    vault.setMinDeposit(2);
    vm.stopPrank();

    vm.startPrank(admin);
    vm.expectRevert(bytes("signer is zero"));
    vault.setSigner(address(0));
    vault.setSigner(bob);
    vm.expectRevert(bytes("same signer"));
    vault.setSigner(bob);
    vm.stopPrank();
  }

  // ─── Views ────────────────────────────────────────────────────────────────

  function test_getUserWithdrawalRequests_pagination() public {
    _deposit(alice, 100e6);
    _requestRedeem(alice, 10e6);
    _requestRedeem(alice, 20e6);
    _requestRedeem(alice, 30e6);

    XAUECardVault.WithdrawalRequest[] memory page = vault.getUserWithdrawalRequests(alice, 1, type(uint256).max);
    assertEq(page.length, 2);
    assertEq(page[0].amount, 20e6);
    assertEq(page[1].amount, 30e6);
    assertEq(vault.getUserWithdrawalRequests(alice, 5, 10).length, 0);
    assertEq(vault.getUserWithdrawalRequests(alice).length, 3);
  }

  function test_accounting_identities_through_full_lifecycle() public {
    _deposit(alice, 300e6);
    _deposit(bob, 200e6);
    uint256 a = _requestRedeem(alice, 100e6);
    uint256 b = _requestRedeem(bob, 50e6);
    _liquidate(alice, 20e6, keccak256("liq"));

    assertEq(vault.totalSupply(), 330e6);
    assertEq(vault.totalPendingRedeem(), 150e6);
    assertEq(xaut.balanceOf(receiver), 500e6, "everything deposited reached XAUE");
    assertEq(xaut.balanceOf(address(vault)), 0);

    _repay(150e6);
    _markClaimable(alice, 0);
    _markClaimable(bob, 0);
    assertEq(vault.reservedForClaims(), 150e6);
    assertEq(vault.totalPendingRedeem(), 0);
    assertEq(vault.withdrawQuota(), 0);

    vm.prank(alice);
    vault.claimWithdraw(a);
    vm.prank(bob);
    vault.claimWithdraw(b);
    assertEq(vault.reservedForClaims(), 0);
    assertEq(xaut.balanceOf(address(vault)), 0);
    assertEq(vault.getUserWithdrawalRequestCount(alice), 0);
    assertEq(vault.getUserWithdrawalRequestCount(bob), 0);
  }
}
