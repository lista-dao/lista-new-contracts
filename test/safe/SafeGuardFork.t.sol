// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { SafeGuard } from "../../src/safe/SafeGuard.sol";
import { Enum } from "../../src/safe/libraries/Enum.sol";

interface ISafe13 {
  function nonce() external view returns (uint256);
  function getThreshold() external view returns (uint256);
  function getOwners() external view returns (address[] memory);
  function isOwner(address) external view returns (bool);
  function approveHash(bytes32) external;
  function getTransactionHash(
    address,
    uint256,
    bytes calldata,
    uint8,
    uint256,
    uint256,
    uint256,
    address,
    address,
    uint256
  ) external view returns (bytes32);
  function execTransaction(
    address,
    uint256,
    bytes calldata,
    uint8,
    uint256,
    uint256,
    uint256,
    address,
    address payable,
    bytes calldata
  ) external payable returns (bool);
}

interface IERC20 {
  function transfer(address, uint256) external returns (bool);
  function approve(address, uint256) external returns (bool);
  function balanceOf(address) external view returns (uint256);
}

/// The guard the Safes run today: per-nonce auditor hash, no delay. v2 keeps the addMessageHash ABI.
interface IOldGuard {
  function executors(address) external view returns (address[] memory);
  function auditors(address) external view returns (address[] memory);
  function addMessageHash(address, uint256[] memory, bytes32[] memory) external;
}

/// BSC fork plumbing. Addresses come from the environment and the suite is skipped without them:
///   SAFEGUARD_OLD_GUARD  guard the Safes run today
///   SAFEGUARD_SAFES      comma-separated Safe 1.3.0 addresses on that guard (first one is used for behaviour tests)
///   SAFEGUARD_SAFE_141   a Safe 1.4.1 on that guard (optional)
/// Runs against live state by default; after the migration, set BSC_FORK_BLOCK (archive BSC_RPC) to a block before it.
abstract contract SafeGuardForkBase is Test {
  IOldGuard OLD;
  address[] safes;
  address safe141;
  address constant MULTISEND_CALL_ONLY = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D; // Safe 1.3.0
  address constant MULTISEND_CALL_ONLY_141 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2; // Safe 1.4.1
  address constant MULTISEND = 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761; // Safe 1.3.0, allows nested delegatecall
  address constant LISTA = 0xFceB31A79F71AC9CBDCF853519c1b12D379EdC46;
  bytes32 constant GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
  address constant TO = address(0xBEEF); // allowlisted recipient after migration
  address constant OUTSIDER = address(0xB0B); // not allowlisted
  address constant REFUND_RECEIVER = address(0xA77AC);
  uint256 constant CAP = 1000 ether;

  ISafe13 safe;
  address executor;
  address[] auditors;
  address[] signers; // `threshold` owners, ascending (Safe requires sorted signatures)

  struct STx {
    address to;
    uint256 value;
    bytes data;
    uint8 op;
    uint256 safeTxGas;
    uint256 baseGas;
    uint256 gasPrice;
    address gasToken;
    address refundReceiver;
  }

  function _fork() internal {
    OLD = IOldGuard(vm.envOr("SAFEGUARD_OLD_GUARD", address(0)));
    safes = vm.envOr("SAFEGUARD_SAFES", ",", new address[](0));
    safe141 = vm.envOr("SAFEGUARD_SAFE_141", address(0));
    if (address(OLD) == address(0) || safes.length == 0) vm.skip(true);
    string memory rpc = vm.envOr("BSC_RPC", string("https://bsc-dataseed.binance.org"));
    uint256 blk = vm.envOr("BSC_FORK_BLOCK", uint256(0));
    if (blk == 0) vm.createSelectFork(rpc);
    else vm.createSelectFork(rpc, blk);
  }

  function _guardOf(address s) internal view returns (address) {
    return address(uint160(uint256(vm.load(s, GUARD_SLOT))));
  }

  function _use(address s) internal {
    safe = ISafe13(s);
    auditors = OLD.auditors(s);
    executor = OLD.executors(s)[0];
    address[] memory o = safe.getOwners();
    for (uint256 i = 1; i < o.length; i++) {
      for (uint256 j = i; j > 0 && o[j - 1] > o[j]; j--) (o[j - 1], o[j]) = (o[j], o[j - 1]);
    }
    delete signers;
    uint256 threshold = safe.getThreshold();
    for (uint256 i; i < threshold; i++) signers.push(o[i]);
  }

  function _call(address to, uint256 value, bytes memory data) internal pure returns (STx memory t) {
    t.to = to;
    t.value = value;
    t.data = data;
  }

  function _transfer(address to, uint256 amt) internal pure returns (STx memory) {
    return _call(LISTA, 0, abi.encodeCall(IERC20.transfer, (to, amt)));
  }

  function _packed(address to, bytes memory data) internal pure returns (bytes memory) {
    return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
  }

  function _batch(address ms, bytes memory txs) internal pure returns (STx memory t) {
    t = _call(ms, 0, abi.encodeWithSignature("multiSend(bytes)", txs));
    t.op = 1;
  }

  /// SafeTx struct hash, the scheme both guards use
  function _structHash(STx memory t) internal view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8,
          t.to,
          t.value,
          keccak256(t.data),
          t.op,
          t.safeTxGas,
          t.baseGas,
          t.gasPrice,
          t.gasToken,
          t.refundReceiver,
          safe.nonce()
        )
      );
  }

  function _registerOnOld(STx memory t) internal {
    uint256[] memory ns = new uint256[](1);
    bytes32[] memory hs = new bytes32[](1);
    (ns[0], hs[0]) = (safe.nonce(), _structHash(t));
    vm.prank(auditors[0]);
    OLD.addMessageHash(address(safe), ns, hs);
  }

  function _sigs(STx memory t) internal returns (bytes memory sigs) {
    bytes32 h = safe.getTransactionHash(
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
    for (uint256 i; i < signers.length; i++) {
      vm.prank(signers[i]);
      safe.approveHash(h);
      sigs = abi.encodePacked(sigs, bytes32(uint256(uint160(signers[i]))), bytes32(0), uint8(1));
    }
  }

  /// owners approve on-chain (v=1 signatures), whitelisted executor submits
  function _run(STx memory t, string memory err) internal {
    bytes memory sigs = _sigs(t);
    if (bytes(err).length != 0) vm.expectRevert(bytes(err));
    vm.prank(executor);
    safe.execTransaction(
      t.to,
      t.value,
      t.data,
      t.op,
      t.safeTxGas,
      t.baseGas,
      t.gasPrice,
      t.gasToken,
      payable(t.refundReceiver),
      sigs
    );
  }

  /// self-call with a gas refund paid in LISTA; v2 rejects any refund
  function _refundTx() internal view returns (STx memory t) {
    t.to = address(safe);
    t.gasPrice = 1;
    t.gasToken = LISTA;
    t.refundReceiver = REFUND_RECEIVER;
    t.baseGas = IERC20(LISTA).balanceOf(address(safe)) - 1e6;
  }
}

/// Migration through the current guard, then the v2 tiers on a real Safe.
contract SafeGuardForkTest is SafeGuardForkBase {
  SafeGuard guard;

  function setUp() public {
    _fork();
    address[] memory targets = new address[](2);
    (targets[0], targets[1]) = (MULTISEND_CALL_ONLY, MULTISEND_CALL_ONLY_141);
    guard = new SafeGuard(targets);
    _migrate(safes[0], MULTISEND_CALL_ONLY);
  }

  /* ============ helpers ============ */

  function _approve(address auditor, STx memory t) internal {
    uint256[] memory ns = new uint256[](1);
    bytes32[] memory hs = new bytes32[](1);
    (ns[0], hs[0]) = (safe.nonce(), _structHash(t));
    vm.prank(auditor);
    guard.addMessageHash(address(safe), ns, hs);
  }

  function _approve2(STx memory t) internal {
    _approve(auditors[0], t);
    _approve(auditors[1], t);
  }

  /* ============ migration ============ */

  /// one multiSend: new guard config first, then setGuard
  function _migrationTx(address s, address ms) internal view returns (STx memory) {
    address[] memory r = new address[](1);
    r[0] = TO;
    bytes memory txs = abi.encodePacked(
      _packed(address(guard), abi.encodeCall(SafeGuard.addExecutors, (OLD.executors(s)))),
      _packed(address(guard), abi.encodeCall(SafeGuard.addAuditors, (OLD.auditors(s)))),
      _packed(address(guard), abi.encodeCall(SafeGuard.addRecipients, (r))),
      _packed(address(guard), abi.encodeCall(SafeGuard.setCap, (LISTA, CAP))),
      _packed(s, abi.encodeWithSignature("setGuard(address)", address(guard)))
    );
    return _batch(ms, txs);
  }

  function _migrate(address s, address ms) internal {
    _use(s);
    assertEq(_guardOf(s), address(OLD), "pre-migration state expected; set BSC_FORK_BLOCK");
    STx memory t = _migrationTx(s, ms);
    _registerOnOld(t); // the current guard wants an auditor hash, no delay
    _run(t, "");
    assertEq(_guardOf(s), address(guard));
  }

  function test_migration_allSafes() public {
    for (uint256 i = 1; i < safes.length; i++) _migrate(safes[i], MULTISEND_CALL_ONLY);
    for (uint256 i; i < safes.length; i++) {
      address s = safes[i];
      _use(s);
      assertEq(_guardOf(s), address(guard));
      assertEq(keccak256(abi.encode(guard.executors(s))), keccak256(abi.encode(OLD.executors(s))));
      assertEq(keccak256(abi.encode(guard.auditors(s))), keccak256(abi.encode(OLD.auditors(s))));
      assertTrue(guard.isRecipient(s, TO));
      assertEq(guard.cap(s, LISTA), CAP);
      _run(_transfer(TO, 1), "SafeGuard: NotApproved"); // new guard is enforcing
      _run(_refundTx(), "SafeGuard: NoRefund");
    }
  }

  function test_migration_needsAuditorHashOnOldGuard() public {
    if (safes.length < 2) vm.skip(true);
    _use(safes[1]);
    _run(_migrationTx(safes[1], MULTISEND_CALL_ONLY), "SafeGuard: InvalidHash");
  }

  /// Safe 1.4.1: setGuard checks ERC165, and Safe UI batches use the 1.4.1 MultiSendCallOnly
  function test_migration_safe141() public {
    if (safe141 == address(0)) vm.skip(true);
    _migrate(safe141, MULTISEND_CALL_ONLY_141);
    STx memory t = _batch(MULTISEND_CALL_ONLY_141, _packed(LISTA, abi.encodeCall(IERC20.approve, (OUTSIDER, 0))));
    _run(t, "SafeGuard: NotApproved");
    _approve(auditors[0], t);
    _run(t, "");
  }

  /* ============ tiers on a real Safe ============ */

  function test_routineTransferRunsNow() public {
    STx memory t = _transfer(TO, 10 ether);
    _approve(auditors[0], t);
    _run(t, "");
    assertEq(IERC20(LISTA).balanceOf(TO), 10 ether);
  }

  function test_transferToOutsiderWaits24h() public {
    STx memory t = _transfer(OUTSIDER, 1);
    _approve2(t); // never emergency for a non-allowlisted recipient
    vm.warp(block.timestamp + 1 days - 1);
    _run(t, "SafeGuard: Timelocked");
    vm.warp(block.timestamp + 1);
    _run(t, "");
    assertEq(IERC20(LISTA).balanceOf(OUTSIDER), 1);
  }

  function test_overCapToRecipient_emergencyWithTwoAuditors() public {
    STx memory t = _transfer(TO, CAP + 1);
    _approve(auditors[0], t);
    _run(t, "SafeGuard: Timelocked");
    _approve(auditors[1], t);
    _run(t, "");
    assertEq(IERC20(LISTA).balanceOf(TO), CAP + 1);
  }

  function test_rejectionBurnsNonceWithoutApproval() public {
    uint256 n = safe.nonce();
    _run(_call(safes[0], 0, ""), "");
    assertEq(safe.nonce(), n + 1);
  }

  function test_refundBlocked() public {
    uint256 bal = IERC20(LISTA).balanceOf(safes[0]);
    STx memory t = _refundTx();
    _approve2(t); // even if auditors were fooled
    vm.warp(block.timestamp + 1 days);
    _run(t, "SafeGuard: NoRefund");
    assertEq(IERC20(LISTA).balanceOf(safes[0]), bal);
  }

  function test_delegateCallAllowlist() public {
    bytes memory inner = _packed(LISTA, abi.encodeCall(IERC20.transfer, (TO, 1)));
    STx memory bad = _batch(MULTISEND, inner);
    _approve2(bad);
    vm.warp(block.timestamp + 1 days);
    _run(bad, "SafeGuard: DelegateCallBlocked");

    STx memory ok = _batch(MULTISEND_CALL_ONLY, inner);
    _approve(auditors[0], ok);
    _run(ok, "");
    assertEq(IERC20(LISTA).balanceOf(TO), 1);
  }

  function test_emergencyRemoveOwner() public {
    address[] memory o = safe.getOwners();
    address gone = o[o.length - 1];
    STx memory t = _call(
      safes[0],
      0,
      abi.encodeWithSignature("removeOwner(address,address,uint256)", o[o.length - 2], gone, safe.getThreshold())
    );
    _approve(auditors[0], t);
    _run(t, "SafeGuard: Timelocked");
    _approve(auditors[1], t);
    _run(t, ""); // same block
    assertFalse(safe.isOwner(gone));
  }

  function test_setGuardIsConfig() public {
    STx memory t = _call(safes[0], 0, abi.encodeWithSignature("setGuard(address)", address(0)));
    _approve(auditors[0], t);
    vm.warp(block.timestamp + 2 days);
    _run(t, "SafeGuard: NotApproved");
    _approve(auditors[1], t);
    _run(t, "SafeGuard: Timelocked");
    vm.warp(block.timestamp + 1 days);
    _run(t, "");
    assertEq(_guardOf(safes[0]), address(0));
  }

  /* ============ escape hatch ============ */

  function test_ownerEscapeReplacesAuditor() public {
    address bad = auditors[0];
    address fresh = address(0xF4E5);
    _run(_call(address(guard), 0, abi.encodeCall(SafeGuard.proposeAuditorReplacement, (bad, fresh))), "");

    vm.expectRevert(bytes("SafeGuard: EscapeNotReady"));
    guard.executeAuditorReplacement(safes[0], bad, fresh);

    vm.warp(block.timestamp + 7 days);
    vm.prank(REFUND_RECEIVER); // anyone
    guard.executeAuditorReplacement(safes[0], bad, fresh);

    address[] memory now_ = guard.auditors(safes[0]);
    assertEq(now_.length, auditors.length);
    bool hasFresh;
    bool hasBad;
    for (uint256 i; i < now_.length; i++) {
      hasFresh = hasFresh || now_[i] == fresh;
      hasBad = hasBad || now_[i] == bad;
    }
    assertTrue(hasFresh);
    assertFalse(hasBad);
  }

  function test_ownerEscapeRemovesGuard() public {
    _run(_call(address(guard), 0, abi.encodeCall(SafeGuard.proposeGuardChange, (address(0)))), "");
    STx memory t = _call(safes[0], 0, abi.encodeWithSignature("setGuard(address)", address(0)));
    _run(t, "SafeGuard: NotApproved");
    vm.warp(block.timestamp + 7 days);
    _run(t, ""); // owners only
    assertEq(_guardOf(safes[0]), address(0));
  }

  function test_escapeExemptionIsExact() public {
    // removeAuditor straight from the Safe is Config
    _run(_call(address(guard), 0, abi.encodeCall(SafeGuard.removeAuditor, (auditors[0]))), "SafeGuard: NotApproved");
  }
}
