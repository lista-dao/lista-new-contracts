// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { GnosisSafeMock } from "./GnosisSafeMock.sol";
import { SafeGuard } from "../../src/safe/SafeGuard.sol";
import { Enum } from "../../src/safe/libraries/Enum.sol";

/// Unit tests against GnosisSafeMock: the mock bumps its nonce and runs checkTransaction, it does not execute the call.
/// Guard configuration is applied by pranking as the Safe. End-to-end behaviour is in SafeGuardFork.t.sol.
contract SGTest is Test {
  address constant MULTISEND_CALL_ONLY = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;
  address constant MULTISEND = 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761;
  address constant SENTINEL = address(0x1);

  GnosisSafeMock safe;
  SafeGuard guard;
  address auditorA = makeAddr("auditorA");
  address auditorB = makeAddr("auditorB");
  address auditorC = makeAddr("auditorC");
  address executor = makeAddr("executor");
  address token = makeAddr("token");
  address recipient = makeAddr("recipient");
  address target = makeAddr("target");
  address stranger = makeAddr("stranger");

  event TxAuthorized(address indexed account, bytes32 indexed safeTxHash, uint8 tier, bool emergency);

  struct STx {
    address to;
    uint256 value;
    bytes data;
    Enum.Operation op;
    uint256 safeTxGas;
    uint256 baseGas;
    uint256 gasPrice;
    address gasToken;
    address refundReceiver;
  }

  function setUp() public {
    vm.warp(1_700_000_000);
    address[] memory targets = new address[](1);
    targets[0] = MULTISEND_CALL_ONLY;
    guard = new SafeGuard(targets);
    safe = new GnosisSafeMock();
    safe.setGuard(address(guard));
    vm.startPrank(address(safe));
    guard.addAuditors(_list3(auditorA, auditorB, auditorC));
    guard.addExecutor(executor);
    guard.addRecipients(_list1(recipient));
    guard.setCap(token, 100);
    vm.stopPrank();
  }

  /* ============ helpers ============ */

  function _list1(address a) internal pure returns (address[] memory l) {
    l = new address[](1);
    l[0] = a;
  }

  function _list3(address a, address b, address c) internal pure returns (address[] memory l) {
    l = new address[](3);
    (l[0], l[1], l[2]) = (a, b, c);
  }

  function _tx(address to, bytes memory data) internal pure returns (STx memory t) {
    t.to = to;
    t.data = data;
  }

  function _transfer(address to, uint256 amt) internal view returns (STx memory) {
    return _tx(token, abi.encodeWithSignature("transfer(address,uint256)", to, amt));
  }

  function _self(bytes memory data) internal view returns (STx memory) {
    return _tx(address(safe), data);
  }

  function _onGuard(bytes memory data) internal view returns (STx memory) {
    return _tx(address(guard), data);
  }

  function _packed(address to, uint256 value, bytes memory data) internal pure returns (bytes memory) {
    return abi.encodePacked(uint8(0), to, value, data.length, data);
  }

  function _batch(bytes memory txs) internal pure returns (STx memory t) {
    t = _tx(MULTISEND_CALL_ONLY, abi.encodeWithSignature("multiSend(bytes)", txs));
    t.op = Enum.Operation.DelegateCall;
  }

  function _hash(STx memory t) internal view returns (bytes32) {
    return
      guard.encodeTransactionData(
        t.to,
        t.value,
        t.data,
        t.op,
        t.safeTxGas,
        t.baseGas,
        t.gasPrice,
        t.gasToken,
        t.refundReceiver,
        safe.nonce()
      );
  }

  function _addHash(address auditor, uint256 n, bytes32 h) internal {
    uint256[] memory ns = new uint256[](1);
    bytes32[] memory hs = new bytes32[](1);
    (ns[0], hs[0]) = (n, h);
    vm.prank(auditor);
    guard.addMessageHash(address(safe), ns, hs);
  }

  function _approve(address auditor, STx memory t) internal returns (bytes32 h) {
    h = _hash(t);
    _addHash(auditor, safe.nonce(), h);
  }

  function _approve2(STx memory t) internal returns (bytes32 h) {
    _approve(auditorA, t);
    h = _approve(auditorB, t);
  }

  function _execAs(address sender, STx memory t) internal {
    vm.prank(sender);
    safe.execTransaction(
      t.to,
      t.value,
      t.data,
      t.op,
      t.safeTxGas,
      t.baseGas,
      t.gasPrice,
      t.gasToken,
      t.refundReceiver,
      ""
    );
  }

  function _exec(STx memory t) internal {
    _execAs(executor, t);
  }

  function _execReverts(STx memory t, string memory err) internal {
    vm.expectRevert(bytes(err));
    _exec(t);
  }

  /// approve with 2 auditors, wait out the delay, and check the tier the guard assigns
  function _assertTier(STx memory t, uint8 tier, bool emergency) internal {
    bytes32 h = _approve2(t);
    vm.warp(block.timestamp + 1 days);
    vm.expectEmit(true, true, false, true, address(guard));
    emit TxAuthorized(address(safe), h, tier, emergency);
    _exec(t);
  }

  function _has(address[] memory l, address a) internal pure returns (bool) {
    for (uint256 i; i < l.length; i++) if (l[i] == a) return true;
    return false;
  }

  /* ============ global checks ============ */

  function test_supportsInterface() public view {
    assertTrue(guard.supportsInterface(0xe6d7a83a));
    assertTrue(guard.supportsInterface(0x01ffc9a7));
    assertFalse(guard.supportsInterface(0xffffffff));
  }

  function test_notExecutor() public {
    STx memory t = _transfer(recipient, 1);
    _approve(auditorA, t);
    vm.expectRevert(bytes("SafeGuard: NotExecutor"));
    _execAs(stranger, t);
  }

  function test_emptyExecutorListAllowsAnyone() public {
    vm.prank(address(safe));
    guard.removeExecutor(executor);
    STx memory t = _transfer(recipient, 1);
    _approve(auditorA, t);
    _execAs(stranger, t);
  }

  function test_noRefund() public {
    STx memory t = _transfer(recipient, 1);
    t.gasPrice = 1;
    _approve2(t);
    vm.warp(block.timestamp + 1 days);
    _execReverts(t, "SafeGuard: NoRefund");
  }

  function test_delegateCallOnlyToAllowlist() public {
    STx memory t = _batch(_packed(token, 0, abi.encodeWithSignature("transfer(address,uint256)", recipient, 1)));
    t.to = MULTISEND;
    _approve2(t);
    vm.warp(block.timestamp + 1 days);
    _execReverts(t, "SafeGuard: DelegateCallBlocked");

    STx memory plain = _tx(stranger, "");
    plain.op = Enum.Operation.DelegateCall;
    _execReverts(plain, "SafeGuard: DelegateCallBlocked");
  }

  function test_noAuditorsOnlyGlobalChecks() public {
    GnosisSafeMock other = new GnosisSafeMock();
    other.setGuard(address(guard));
    vm.prank(address(other));
    other.execTransaction(stranger, 1 ether, "", Enum.Operation.Call, 0, 0, 0, address(0), address(0), "");
    vm.expectRevert(bytes("SafeGuard: NoRefund"));
    other.execTransaction(address(other), 0, "", Enum.Operation.Call, 0, 0, 1, address(0), address(0), "");
  }

  /* ============ rejection ============ */

  function test_rejectionNeedsNoApproval() public {
    uint256 n = safe.nonce();
    _exec(_self(""));
    assertEq(safe.nonce(), n + 1);
  }

  function testFuzz_rejectionWithAnyFieldSetNeedsApproval(uint8 which, uint96 x) public {
    vm.assume(x != 0);
    STx memory t = _self("");
    which = which % 6;
    if (which == 0) t.value = x;
    else if (which == 1) t.data = hex"00";
    else if (which == 2) t.safeTxGas = x;
    else if (which == 3) t.baseGas = x;
    else if (which == 4) t.gasToken = address(uint160(x));
    else t.refundReceiver = address(uint160(x));
    _execReverts(t, "SafeGuard: NotApproved");
  }

  /* ============ transfers, recipients and caps ============ */

  function test_routineTransferWithinCap() public {
    STx memory t = _transfer(recipient, 60);
    bytes32 h = _approve(auditorA, t);
    uint8 routine = guard.ROUTINE();
    vm.expectEmit(true, true, false, true, address(guard));
    emit TxAuthorized(address(safe), h, routine, false);
    _exec(t);
    assertEq(guard.spent(address(safe), token, block.timestamp / 1 days), 60);
  }

  function test_routineNeedsOneApproval() public {
    _execReverts(_transfer(recipient, 1), "SafeGuard: NotApproved");
  }

  function test_capIsCumulativePerDay() public {
    STx memory a = _transfer(recipient, 60);
    _approve(auditorA, a);
    _exec(a);

    STx memory b = _transfer(recipient, 50); // 110 > 100
    _approve(auditorA, b);
    _execReverts(b, "SafeGuard: Timelocked");

    vm.warp((block.timestamp / 1 days + 1) * 1 days); // next UTC day
    _exec(b);
  }

  function test_overCapToRecipient_delayOrTwoAuditors() public {
    STx memory t = _transfer(recipient, 150);
    _approve(auditorA, t);
    _execReverts(t, "SafeGuard: Timelocked");
    vm.warp(block.timestamp + 1 days - 1);
    _execReverts(t, "SafeGuard: Timelocked");
    vm.warp(block.timestamp + 1);
    _exec(t);

    STx memory e = _transfer(recipient, 150);
    _approve2(e);
    _exec(e); // emergency: no delay
  }

  function test_nonRecipientNeverEmergency() public {
    STx memory t = _transfer(stranger, 1);
    _approve2(t);
    _execReverts(t, "SafeGuard: Timelocked");
    vm.warp(block.timestamp + 1 days);
    _exec(t);
  }

  function test_approveZeroIsRoutine() public {
    STx memory t = _tx(token, abi.encodeWithSignature("approve(address,uint256)", stranger, 0));
    _approve(auditorA, t);
    _exec(t);
  }

  function test_approveMaxOverCapIsCriticalNotOverflow() public {
    STx memory a = _transfer(recipient, 1);
    _approve(auditorA, a);
    _exec(a);
    STx memory t = _tx(token, abi.encodeWithSignature("approve(address,uint256)", recipient, type(uint256).max));
    _assertTier(t, guard.CRITICAL(), true);
  }

  function test_transferFromIntoSafeIsRoutine() public {
    STx memory t = _tx(token, abi.encodeWithSignature("transferFrom(address,address,uint256)", stranger, address(safe), 1e30));
    _approve(auditorA, t);
    _exec(t);
  }

  function test_nativeValueUsesNativeCap() public {
    STx memory t = _tx(recipient, "");
    t.value = 10;
    _assertTier(t, guard.CRITICAL(), true); // native cap is 0

    vm.prank(address(safe));
    guard.setCap(address(0), 100);
    STx memory u = _tx(recipient, "");
    u.value = 10;
    _approve(auditorA, u);
    _exec(u);
  }

  function test_unknownCallIsCritical() public {
    _assertTier(_tx(target, abi.encodeWithSignature("setOracle(address)", stranger)), guard.CRITICAL(), true);
  }

  function test_dirtyAddressReverts() public {
    STx memory t = _tx(token, abi.encodePacked(bytes4(0xa9059cbb), bytes32(uint256(1) << 200), uint256(1)));
    _approve(auditorA, t);
    _execReverts(t, "SafeGuard: DirtyAddress");
  }

  /* ============ allowlisted calls ============ */

  bytes4 constant WITHDRAW = bytes4(keccak256("withdraw(uint256,address)"));

  function _withdraw(address to) internal view returns (STx memory) {
    return _tx(target, abi.encodeWithSelector(WITHDRAW, uint256(5), to));
  }

  function test_routineRuleChecksRecipientParam() public {
    uint8 routine = guard.ROUTINE();
    vm.prank(address(safe));
    guard.setRule(target, WITHDRAW, routine, 2); // word 1 = receiver

    STx memory ok = _withdraw(recipient);
    _approve(auditorA, ok);
    _exec(ok);

    STx memory self = _withdraw(address(safe));
    _approve(auditorA, self);
    _exec(self);

    _assertTier(_withdraw(stranger), guard.CRITICAL(), false);
  }

  function test_pauseRuleNeedsNoApproval() public {
    bytes4 pause = bytes4(keccak256("pause()"));
    uint8 tier = guard.PAUSE();
    vm.prank(address(safe));
    guard.setRule(target, pause, tier, 0);
    _exec(_tx(target, abi.encodeWithSelector(pause)));
  }

  function test_setRuleValidation() public {
    uint8 routine = guard.ROUTINE();
    vm.startPrank(address(safe));
    vm.expectRevert(bytes("SafeGuard: DeniedSelector"));
    guard.setRule(target, bytes4(keccak256("upgradeTo(address)")), routine, 0);
    vm.expectRevert(bytes("SafeGuard: DeniedSelector"));
    guard.setRule(target, bytes4(keccak256("grantRole(bytes32,address)")), routine, 0);
    vm.expectRevert(bytes("SafeGuard: DeniedSelector"));
    guard.setRule(target, bytes4(keccak256("unpause()")), routine, 0);
    vm.expectRevert(bytes("SafeGuard: InvalidTier"));
    guard.setRule(target, WITHDRAW, 3, 0);
    vm.expectRevert(bytes("SafeGuard: InvalidTarget"));
    guard.setRule(address(safe), WITHDRAW, routine, 0);
    vm.expectRevert(bytes("SafeGuard: InvalidTarget"));
    guard.setRule(address(guard), WITHDRAW, routine, 0);
    vm.stopPrank();
  }

  /* ============ Safe self-calls ============ */

  function _removeOwner(uint256 threshold) internal view returns (STx memory) {
    return _self(abi.encodeWithSignature("removeOwner(address,address,uint256)", SENTINEL, stranger, threshold));
  }

  function test_removeOwnerKeepingThresholdIsEmergencyEligible() public {
    STx memory t = _removeOwner(2);
    _approve2(t);
    _exec(t); // same block
  }

  function test_removeOwnerLoweringThresholdIsConfig() public {
    _assertTier(_removeOwner(1), guard.CONFIG(), false);
  }

  function test_swapOwnerNeverEmergency() public {
    STx memory t = _self(abi.encodeWithSignature("swapOwner(address,address,address)", SENTINEL, stranger, target));
    _approve2(t);
    _execReverts(t, "SafeGuard: Timelocked");
    vm.warp(block.timestamp + 1 days);
    _exec(t);
  }

  function test_changeThreshold() public {
    _assertTier(_self(abi.encodeWithSignature("changeThreshold(uint256)", 3)), guard.CRITICAL(), true);
    _assertTier(_self(abi.encodeWithSignature("changeThreshold(uint256)", 1)), guard.CONFIG(), false);
  }

  function test_safeSettingsAreConfig() public {
    _assertTier(_self(abi.encodeWithSignature("setGuard(address)", address(0))), guard.CONFIG(), false);
    _assertTier(_self(abi.encodeWithSignature("enableModule(address)", stranger)), guard.CONFIG(), false);
    _assertTier(_self(abi.encodeWithSignature("setFallbackHandler(address)", stranger)), guard.CONFIG(), false);
    _assertTier(_self(abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", stranger, 2)), guard.CONFIG(), false);
  }

  /* ============ Config timing ============ */

  function test_configNeedsTwoAuditors() public {
    STx memory t = _self(abi.encodeWithSignature("setGuard(address)", address(0)));
    _approve(auditorA, t);
    vm.warp(block.timestamp + 3 days);
    _execReverts(t, "SafeGuard: NotApproved");
  }

  function test_configClockStartsAtSecondApproval() public {
    STx memory t = _self(abi.encodeWithSignature("setGuard(address)", address(0)));
    _approve(auditorA, t);
    vm.warp(block.timestamp + 23 hours);
    _approve(auditorB, t);
    vm.warp(block.timestamp + 23 hours);
    _execReverts(t, "SafeGuard: Timelocked");
    vm.warp(block.timestamp + 1 hours);
    _exec(t);
  }

  function test_configExpires() public {
    STx memory t = _self(abi.encodeWithSignature("setGuard(address)", address(0)));
    _approve2(t);
    vm.warp(block.timestamp + 7 days);
    _execReverts(t, "SafeGuard: Expired");
  }

  /* ============ guard list changes ============ */

  function test_guardListChangesAreConfig() public {
    uint8 config = guard.CONFIG();
    _assertTier(_onGuard(abi.encodeCall(SafeGuard.addRecipients, (_list1(stranger)))), config, false);
    _assertTier(_onGuard(abi.encodeCall(SafeGuard.addAuditor, (stranger))), config, false);
    _assertTier(_onGuard(abi.encodeCall(SafeGuard.setRule, (target, WITHDRAW, 2, 0))), config, false);
    _assertTier(_onGuard(abi.encodeCall(SafeGuard.setCap, (token, 99))), config, false);
    _assertTier(_onGuard(abi.encodeCall(SafeGuard.removeRecipient, (recipient))), config, false);
    _assertTier(_onGuard(abi.encodeCall(SafeGuard.removeExecutor, (executor))), config, false);
    // a batch emptying the executor list is Config too
    vm.prank(address(safe));
    guard.addExecutor(stranger);
    bytes memory txs = abi.encodePacked(
      _packed(address(guard), 0, abi.encodeCall(SafeGuard.removeExecutor, (executor))),
      _packed(address(guard), 0, abi.encodeCall(SafeGuard.removeExecutor, (stranger)))
    );
    _assertTier(_batch(txs), config, false);
  }

  /* ============ batches ============ */

  function test_batchTakesStrictestTier() public {
    bytes memory txs = abi.encodePacked(
      _packed(token, 0, abi.encodeWithSignature("transfer(address,uint256)", recipient, 1)),
      _packed(address(safe), 0, abi.encodeWithSignature("setGuard(address)", address(0)))
    );
    _assertTier(_batch(txs), guard.CONFIG(), false);
  }

  function test_batchSumsCap() public {
    bytes memory one = _packed(token, 0, abi.encodeWithSignature("transfer(address,uint256)", recipient, 60));
    _assertTier(_batch(abi.encodePacked(one, one)), guard.CRITICAL(), true);
  }

  function test_batchWithinCapIsRoutine() public {
    bytes memory one = _packed(token, 0, abi.encodeWithSignature("transfer(address,uint256)", recipient, 40));
    STx memory t = _batch(abi.encodePacked(one, one));
    _approve(auditorA, t);
    _exec(t);
    assertEq(guard.spent(address(safe), token, block.timestamp / 1 days), 80);
  }

  function test_batchZeroTargetIsTheSafe() public {
    _assertTier(_batch(_packed(address(0), 0, abi.encodeWithSignature("setGuard(address)", address(0)))), guard.CONFIG(), false);
  }

  function test_batchInnerDelegateCallReverts() public {
    bytes memory inner = abi.encodePacked(uint8(1), token, uint256(0), uint256(0));
    STx memory t = _batch(inner);
    _approve2(t);
    _execReverts(t, "SafeGuard: InnerDelegateCall");
  }

  function test_batchMalformedReverts() public {
    bytes memory txs = _packed(token, 0, abi.encodeWithSignature("transfer(address,uint256)", recipient, 1));
    bytes memory cut = new bytes(txs.length - 1);
    for (uint256 i; i < cut.length; i++) cut[i] = txs[i];
    _execReverts(_batch(cut), "SafeGuard: BadBatch");

    STx memory notMs = _tx(MULTISEND_CALL_ONLY, abi.encodeWithSignature("foo(bytes)", txs));
    notMs.op = Enum.Operation.DelegateCall;
    _execReverts(notMs, "SafeGuard: NotMultiSend");
  }

  function test_batchOfPausesNeedsNoApproval() public {
    bytes4 pause = bytes4(keccak256("pause()"));
    uint8 tier = guard.PAUSE();
    vm.prank(address(safe));
    guard.setRule(target, pause, tier, 0);
    bytes memory p = _packed(target, 0, abi.encodeWithSelector(pause));
    _exec(_batch(abi.encodePacked(p, p)));
  }

  /* ============ approvals ============ */

  function test_onlyAuditorsApprove() public {
    vm.expectRevert(bytes("SafeGuard: NotAuditor"));
    _addHash(stranger, 0, keccak256("x"));
  }

  function test_addMessageHashValidation() public {
    _exec(_self("")); // nonce 1
    vm.expectRevert(bytes("SafeGuard: ZeroHash"));
    _addHash(auditorA, 1, bytes32(0));
    vm.expectRevert(bytes("SafeGuard: Nonce not valid"));
    _addHash(auditorA, 0, keccak256("x"));
    uint256[] memory ns = new uint256[](2);
    bytes32[] memory hs = new bytes32[](1);
    vm.prank(auditorA);
    vm.expectRevert(bytes("SafeGuard: ZeroHash"));
    guard.addMessageHash(address(safe), ns, hs);
  }

  function test_addMessageHashBatch() public {
    STx memory t = _transfer(recipient, 1);
    uint256 n = safe.nonce();
    uint256[] memory ns = new uint256[](2);
    bytes32[] memory hs = new bytes32[](2);
    (ns[0], hs[0]) = (n, keccak256("other"));
    (ns[1], hs[1]) = (n, _hash(t));
    vm.prank(auditorA);
    guard.addMessageHash(address(safe), ns, hs);
    _exec(t);
  }

  /// same auditor re-adding a live hash is a no-op: no revert, and it still counts once
  function test_reAddingHashIsNoop() public {
    STx memory t = _transfer(stranger, 1);
    bytes32 h = _approve(auditorA, t);
    _approve(auditorA, t);
    (address a1, , address a2, ) = guard.approvals(address(safe), h);
    assertEq(a1, auditorA);
    assertEq(a2, address(0));
    _execReverts(t, "SafeGuard: Timelocked");
  }

  /// a fully expired approval is renewed (clock restarts) by adding the hash again
  function test_expiredApprovalRenews() public {
    STx memory t = _transfer(stranger, 1);
    _approve(auditorA, t);
    vm.warp(block.timestamp + 7 days);
    _execReverts(t, "SafeGuard: Expired");
    _approve(auditorA, t);
    _execReverts(t, "SafeGuard: Timelocked");
    vm.warp(block.timestamp + 1 days);
    _exec(t);
  }


  function test_approvalExpires() public {
    STx memory t = _transfer(stranger, 1);
    _approve(auditorA, t);
    vm.warp(block.timestamp + 7 days - 1);
    _exec(t);

    STx memory u = _transfer(recipient, 1);
    _approve(auditorA, u);
    vm.warp(block.timestamp + 7 days);
    _execReverts(u, "SafeGuard: Expired");
  }

  function test_removedAuditorsApprovalStopsCounting() public {
    STx memory t = _self(abi.encodeWithSignature("setGuard(address)", address(0)));
    _approve2(t);
    vm.prank(address(safe));
    guard.removeAuditor(auditorA);
    vm.warp(block.timestamp + 1 days);
    _execReverts(t, "SafeGuard: NotApproved"); // Config needs 2 live approvals

    _approve(auditorC, t); // takes the dead slot; Config clock restarts at this approval
    _execReverts(t, "SafeGuard: Timelocked");
    vm.warp(block.timestamp + 1 days);
    _exec(t);
  }

  function test_otherAuditorRemovalKeepsApprovals() public {
    STx memory t = _transfer(recipient, 1);
    _approve(auditorA, t);
    vm.prank(address(safe));
    guard.removeAuditor(auditorC);
    _exec(t);
  }

  function test_removeAuditorKeepsMinimum() public {
    vm.startPrank(address(safe));
    guard.removeAuditor(auditorC);
    vm.expectRevert(bytes("SafeGuard: TooFewAuditors"));
    guard.removeAuditor(auditorB);
    guard.addAuditor(stranger); // replace = add, then remove
    guard.removeAuditor(auditorB);
    vm.stopPrank();
    assertTrue(_has(guard.auditors(address(safe)), stranger));
  }

  /* ============ escape hatch ============ */

  function test_escapeCallsNeedNoApproval() public {
    _exec(_onGuard(abi.encodeCall(SafeGuard.proposeAuditorReplacement, (auditorA, stranger))));
    _exec(_onGuard(abi.encodeCall(SafeGuard.proposeGuardChange, (address(0)))));
    _exec(_onGuard(abi.encodeCall(SafeGuard.cancelEscape, (bytes32(0)))));
  }

  function test_escapeNeedsNoExecutor() public {
    // every executor lost: the owners still reach the escape hatch
    _execAs(stranger, _onGuard(abi.encodeCall(SafeGuard.proposeAuditorReplacement, (auditorA, target))));
    _execAs(stranger, _onGuard(abi.encodeCall(SafeGuard.proposeGuardChange, (address(0)))));
    _execAs(stranger, _onGuard(abi.encodeCall(SafeGuard.cancelEscape, (bytes32(0)))));

    vm.prank(address(safe));
    guard.proposeGuardChange(address(0));
    vm.warp(block.timestamp + 7 days);
    _execAs(stranger, _self(abi.encodeWithSignature("setGuard(address)", address(0))));
    assertEq(guard.escapeEta(address(safe), guard.guardEscapeId(address(0))), 0);

    // anything else still needs an executor
    vm.expectRevert(bytes("SafeGuard: NotExecutor"));
    _execAs(stranger, _self(""));
    bytes memory padded = abi.encodePacked(abi.encodeCall(SafeGuard.proposeGuardChange, (address(0))), uint8(0));
    vm.expectRevert(bytes("SafeGuard: NotExecutor"));
    _execAs(stranger, _onGuard(padded));
  }

  function test_escapeExemptionIsExact() public {
    _execReverts(_onGuard(abi.encodeCall(SafeGuard.removeAuditor, (auditorA))), "SafeGuard: NotApproved");
    bytes memory padded = abi.encodePacked(abi.encodeCall(SafeGuard.proposeGuardChange, (address(0))), uint8(0));
    _execReverts(_onGuard(padded), "SafeGuard: NotApproved");
    STx memory withValue = _onGuard(abi.encodeCall(SafeGuard.proposeGuardChange, (address(0))));
    withValue.value = 1;
    _execReverts(withValue, "SafeGuard: NotApproved");
    // inside a batch the escape call is plain Config
    _assertTier(
      _batch(_packed(address(guard), 0, abi.encodeCall(SafeGuard.proposeGuardChange, (address(0))))),
      guard.CONFIG(),
      false
    );
  }

  function test_auditorEscapeReplaces() public {
    STx memory pending = _transfer(stranger, 1);
    _approve(auditorA, pending);

    vm.prank(address(safe));
    guard.proposeAuditorReplacement(auditorA, stranger);
    vm.expectRevert(bytes("SafeGuard: EscapeNotReady"));
    guard.executeAuditorReplacement(address(safe), auditorA, stranger);

    vm.warp(block.timestamp + 7 days);
    vm.prank(target); // anyone
    guard.executeAuditorReplacement(address(safe), auditorA, stranger);

    address[] memory now_ = guard.auditors(address(safe));
    assertEq(now_.length, 3);
    assertTrue(_has(now_, stranger));
    assertFalse(_has(now_, auditorA));
    _execReverts(pending, "SafeGuard: NotApproved"); // the replaced auditor's approval no longer counts

    vm.expectRevert(bytes("SafeGuard: EscapeNotReady"));
    guard.executeAuditorReplacement(address(safe), auditorA, stranger); // one-shot
  }

  function test_escapeProposalValidation() public {
    vm.startPrank(address(safe));
    vm.expectRevert(bytes("SafeGuard: InvalidAuditor"));
    guard.proposeAuditorReplacement(stranger, target);
    vm.expectRevert(bytes("SafeGuard: AuditorExists"));
    guard.proposeAuditorReplacement(auditorA, auditorB);
    vm.expectRevert(bytes("SafeGuard: AuditorExists"));
    guard.proposeAuditorReplacement(auditorA, auditorA);
    vm.stopPrank();
  }

  function test_escapeRemovalKeepsMinimum() public {
    vm.startPrank(address(safe));
    guard.proposeAuditorReplacement(auditorA, address(0));
    guard.proposeAuditorReplacement(auditorB, address(0));
    vm.stopPrank();
    vm.warp(block.timestamp + 7 days);
    guard.executeAuditorReplacement(address(safe), auditorA, address(0));
    vm.expectRevert(bytes("SafeGuard: TooFewAuditors"));
    guard.executeAuditorReplacement(address(safe), auditorB, address(0));
  }



  function test_safeCancelsEscape() public {
    bytes32 id = guard.guardEscapeId(address(0));
    vm.startPrank(address(safe));
    guard.proposeGuardChange(address(0));
    guard.cancelEscape(id);
    vm.expectRevert(bytes("SafeGuard: NoEscape"));
    guard.cancelEscape(id);
    vm.stopPrank();
  }

  function test_guardEscapeAllowsSetGuardWithoutAuditors() public {
    STx memory t = _self(abi.encodeWithSignature("setGuard(address)", address(0)));
    _execReverts(t, "SafeGuard: NotApproved");

    vm.prank(address(safe));
    guard.proposeGuardChange(address(0));
    vm.warp(block.timestamp + 7 days - 1);
    _execReverts(t, "SafeGuard: NotApproved");
    vm.warp(block.timestamp + 1);
    _exec(t);
    assertEq(guard.escapeEta(address(safe), guard.guardEscapeId(address(0))), 0);

    // only the proposed guard
    vm.prank(address(safe));
    guard.proposeGuardChange(address(0));
    vm.warp(block.timestamp + 7 days);
    _execReverts(_self(abi.encodeWithSignature("setGuard(address)", stranger)), "SafeGuard: NotApproved");
  }
}
