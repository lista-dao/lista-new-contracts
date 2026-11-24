// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity 0.8.24;

import { BaseTransactionGuard } from "./BaseTransactionGuard.sol";
import { ISafe } from "./interfaces/ISafe.sol";
import { IOwnerManager } from "./interfaces/IOwnerManager.sol";
import { IGuardManager } from "./interfaces/IGuardManager.sol";
import { Enum } from "./libraries/Enum.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface ITokenOps {
  function transfer(address to, uint256 amount) external;
  function approve(address spender, uint256 amount) external;
  function increaseAllowance(address spender, uint256 amount) external;
  function transferFrom(address from, address to, uint256 amount) external;
}

/// @dev Selectors that can never be allowlisted as Routine / Pause: they always stay Critical.
interface IDenied {
  function upgradeTo(address impl) external;
  function upgradeToAndCall(address impl, bytes calldata data) external;
  function upgrade(address proxy, address impl) external;
  function upgradeAndCall(address proxy, address impl, bytes calldata data) external;
  function grantRole(bytes32 role, address account) external;
  function transferOwnership(address owner) external;
  function unpause() external;
}

interface IMultiSend {
  function multiSend(bytes memory transactions) external;
}

/**
 * @title SafeGuard v2 - tiered auditor approvals, timelock, recipient allowlist and transfer caps.
 * @author Lista
 * @notice Every Safe tx (or MultiSendCallOnly batch, taking its strictest inner op) falls in one tier:
 *  - Rejection (to = Safe, everything else zero) and Pause (allowlisted pause calls): no auditor.
 *  - Routine: allowlisted calls whose recipient params are the Safe or allowlisted, transfers within the
 *    daily cap to allowlisted recipients: 1 auditor, no delay.
 *  - Critical: everything not classified, over-cap or non-allowlisted transfers, owner removal / swap, raising
 *    the threshold, tightening guard lists: 1 auditor + 24h, or 2 auditors with no delay when every recipient
 *    is allowlisted (emergency; never for swapOwner).
 *  - Config: Safe settings (guard, modules, fallback handler, adding owners, lowering threshold) and loosening
 *    guard lists: 2 auditors + 24h from the second approval, no bypass.
 * Owners alone can replace an auditor or change the guard after a 7-day escape delay; only the Safe can cancel it. Gas refunds and delegatecalls other than to the constructor-fixed targets are always blocked.
 */
contract SafeGuard is BaseTransactionGuard {
  using EnumerableSet for EnumerableSet.AddressSet;

  /* ============ Constants ============ */
  // tiers, ordered by strictness
  uint8 public constant PAUSE = 1;
  uint8 public constant ROUTINE = 2;
  uint8 public constant CRITICAL = 3;
  uint8 public constant CONFIG = 4;

  uint256 public constant DELAY = 24 hours;
  // approvals of a hash are usable until its first (still valid) approval + HASH_TTL
  uint256 public constant HASH_TTL = 7 days;
  uint256 public constant ESCAPE_DELAY = 7 days;
  // auditors needed for Config / emergency
  uint256 public constant MIN_AUDITORS = 2;
  bytes32 private constant SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;

  /* ============ Types ============ */
  /// @dev Two approval slots; a slot counts only while its holder is still an auditor of the Safe.
  struct Approval {
    address a1;
    uint64 t1;
    address a2;
    uint64 t2;
  }

  struct Rule {
    uint8 tier; // PAUSE or ROUTINE
    uint248 recipientWords; // bit i set: calldata param word i is an address that must be the Safe or allowlisted
  }

  /* ============ Global States ============ */
  // delegatecall targets allowed for every Safe (MultiSendCallOnly only), fixed at deploy
  mapping(address => bool) public delegateAllowed;

  // account => executors
  mapping(address => EnumerableSet.AddressSet) private _executors;
  // account => auditors
  mapping(address => EnumerableSet.AddressSet) private _auditors;
  // account => safeTxHash => approval
  mapping(address => mapping(bytes32 => Approval)) public approvals;

  // account => recipient => allowlisted
  mapping(address => mapping(address => bool)) public isRecipient;
  // account => token (address(0) = native) => daily cap
  mapping(address => mapping(address => uint256)) public cap;
  // account => token => UTC day => amount sent / approved within cap
  mapping(address => mapping(address => mapping(uint256 => uint256))) public spent;
  // account => target => selector => rule
  mapping(address => mapping(address => mapping(bytes4 => Rule))) public rules;

  // account => escape id => executable from
  mapping(address => mapping(bytes32 => uint256)) public escapeEta;

  /* ============ Events ============ */
  event ExecutorAdded(address indexed account, address indexed executor);
  event ExecutorRemoved(address indexed account, address indexed executor);
  event AuditorAdded(address indexed account, address indexed auditor);
  event AuditorRemoved(address indexed account, address indexed auditor);
  event Approved(address indexed account, bytes32 indexed safeTxHash, address indexed auditor, uint256 count);
  event RecipientSet(address indexed account, address indexed recipient, bool allowed);
  event CapSet(address indexed account, address indexed token, uint256 amount);
  event RuleSet(address indexed account, address indexed target, bytes4 selector, uint8 tier, uint248 recipientWords);
  event EscapeProposed(address indexed account, bytes32 indexed id, uint256 eta);
  event EscapeCancelled(address indexed account, bytes32 indexed id);
  event EscapeExecuted(address indexed account, bytes32 indexed id);
  event TxAuthorized(address indexed account, bytes32 indexed safeTxHash, uint8 tier, bool emergency);
  event SafeTxData(
    address to,
    uint256 value,
    bytes data,
    uint8 operation,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    address refundReceiver,
    uint256 nonce,
    bytes32 messagehash
  );

  constructor(address[] memory _delegateTargets) {
    for (uint256 i; i < _delegateTargets.length; i++) {
      delegateAllowed[_delegateTargets[i]] = true;
    }
  }

  // solhint-disable-next-line payable-fallback
  fallback() external {
    // We don't revert on fallback to avoid issues in case of a Safe upgrade
    // E.g. The expected check method might change and then the Safe would be locked.
  }

  modifier onlyContract() {
    require(isContract(msg.sender), "SafeGuard: Contract is not allowed");
    _;
  }

  modifier onlyAuditor(address _vault) {
    require(_auditors[_vault].contains(msg.sender), "SafeGuard: NotAuditor");
    _;
  }

  /* ============ Auditors ============ */

  /// @notice Approve safeTxHashes the auditor recomputed independently; the tier is decided at execution.
  /// Same ABI as the previous SafeGuard. Each hash already commits to its nonce, so `_nonce_list` is only sanity-checked.
  /// Re-adding a live approval is a no-op (bot retries do not revert); re-adding an expired one renews it.
  function addMessageHash(
    address _vault,
    uint256[] memory _nonce_list,
    bytes32[] memory _hash_list
  ) external onlyAuditor(_vault) {
    require(_nonce_list.length == _hash_list.length, "SafeGuard: ZeroHash");
    uint256 current = ISafe(_vault).nonce();
    for (uint256 i; i < _hash_list.length; ++i) {
      require(_hash_list[i] != bytes32(0), "SafeGuard: ZeroHash");
      require(_nonce_list[i] >= current, "SafeGuard: Nonce not valid");
      _approve(_vault, _hash_list[i]);
    }
  }

  function _approve(address _vault, bytes32 _hash) private {
    Approval storage a = approvals[_vault][_hash];
    (uint256 c, uint256 first, ) = _count(_vault, a);
    if (c != 0 && block.timestamp >= first + HASH_TTL) {
      delete approvals[_vault][_hash];
      c = 0;
    }
    if (a.a1 == msg.sender || a.a2 == msg.sender) return;
    if (!_live(_vault, a.a1)) (a.a1, a.t1) = (msg.sender, uint64(block.timestamp));
    else if (!_live(_vault, a.a2)) (a.a2, a.t2) = (msg.sender, uint64(block.timestamp));
    else return;
    emit Approved(_vault, _hash, msg.sender, c + 1);
  }

  function _live(address _vault, address _auditor) private view returns (bool) {
    return _auditor != address(0) && _auditors[_vault].contains(_auditor);
  }

  /// @return c valid approvals, first / second their timestamps in order (second is 0 unless c == 2)
  function _count(address _vault, Approval storage a) private view returns (uint256 c, uint256 first, uint256 second) {
    bool v1 = _live(_vault, a.a1);
    bool v2 = _live(_vault, a.a2);
    if (v1 && v2) return (2, a.t1 < a.t2 ? a.t1 : a.t2, a.t1 < a.t2 ? a.t2 : a.t1);
    if (v1) return (1, a.t1, 0);
    if (v2) return (1, a.t2, 0);
  }

  /* ============ Escape hatch ============ */

  function auditorEscapeId(address _old, address _new) public pure returns (bytes32) {
    return keccak256(abi.encode("auditor", _old, _new));
  }

  function guardEscapeId(address _guard) public pure returns (bytes32) {
    return keccak256(abi.encode("guard", _guard));
  }

  /// @notice Owners replace (or, with `_new` = 0, remove) an auditor after ESCAPE_DELAY. Needs no auditor approval.
  function proposeAuditorReplacement(address _old, address _new) external onlyContract {
    EnumerableSet.AddressSet storage axe = _auditors[msg.sender];
    require(axe.contains(_old), "SafeGuard: InvalidAuditor");
    require(_new == address(0) || !axe.contains(_new), "SafeGuard: AuditorExists");
    _propose(auditorEscapeId(_old, _new));
  }

  /// @notice Owners may run `setGuard(_guard)` without auditor approval after ESCAPE_DELAY.
  function proposeGuardChange(address _guard) external onlyContract {
    _propose(guardEscapeId(_guard));
  }

  function _propose(bytes32 _id) private {
    uint256 eta = block.timestamp + ESCAPE_DELAY;
    escapeEta[msg.sender][_id] = eta;
    emit EscapeProposed(msg.sender, _id, eta);
  }

  /// @notice The Safe withdraws its own escape. Needs no auditor approval.
  function cancelEscape(bytes32 _id) external onlyContract {
    require(escapeEta[msg.sender][_id] != 0, "SafeGuard: NoEscape");
    delete escapeEta[msg.sender][_id];
    emit EscapeCancelled(msg.sender, _id);
  }

  /// @notice Anyone can apply a matured auditor escape.
  function executeAuditorReplacement(address _vault, address _old, address _new) external {
    _consumeEscape(_vault, auditorEscapeId(_old, _new));
    _replaceAuditor(_vault, _old, _new);
  }

  function _consumeEscape(address _vault, bytes32 _id) private {
    uint256 eta = escapeEta[_vault][_id];
    require(eta != 0 && block.timestamp >= eta, "SafeGuard: EscapeNotReady");
    delete escapeEta[_vault][_id];
    emit EscapeExecuted(_vault, _id);
  }

  /* ============ Safe configuration (msg.sender = Safe) ============ */

  function addExecutors(address[] calldata _executorsList) external onlyContract {
    require(_executorsList.length > 0, "SafeGuard: InvalidExecutors");
    for (uint256 i; i < _executorsList.length; i++) _addExecutor(_executorsList[i]);
  }

  function addExecutor(address _executor) external onlyContract {
    _addExecutor(_executor);
  }

  function _addExecutor(address _executor) private {
    require(_executor != address(0), "SafeGuard: ZeroAddress");
    require(_executors[msg.sender].add(_executor), "SafeGuard: ExecutorExists");
    emit ExecutorAdded(msg.sender, _executor);
  }

  /// @dev An empty executor list means any address may execute (intended).
  function removeExecutor(address _executor) external onlyContract {
    require(_executors[msg.sender].remove(_executor), "SafeGuard: InvalidExecutor");
    emit ExecutorRemoved(msg.sender, _executor);
  }

  function addAuditors(address[] calldata _auditorsList) external onlyContract {
    require(_auditorsList.length > 0, "SafeGuard: InvalidAuditors");
    for (uint256 i; i < _auditorsList.length; i++) _addAuditor(msg.sender, _auditorsList[i]);
  }

  function addAuditor(address _auditor) external onlyContract {
    _addAuditor(msg.sender, _auditor);
  }

  function _addAuditor(address _vault, address _auditor) private {
    require(_auditor != address(0), "SafeGuard: ZeroAddress");
    require(_auditors[_vault].add(_auditor), "SafeGuard: AuditorExists");
    emit AuditorAdded(_vault, _auditor);
  }

  function removeAuditor(address _auditor) external onlyContract {
    _replaceAuditor(msg.sender, _auditor, address(0));
  }

  /// @dev A removed auditor's approvals stop counting at once. A plain removal must leave MIN_AUDITORS.
  function _replaceAuditor(address _vault, address _old, address _new) private {
    EnumerableSet.AddressSet storage axe = _auditors[_vault];
    require(axe.remove(_old), "SafeGuard: InvalidAuditor");
    emit AuditorRemoved(_vault, _old);
    if (_new != address(0)) _addAuditor(_vault, _new);
    else require(axe.length() >= MIN_AUDITORS, "SafeGuard: TooFewAuditors");
  }

  function addRecipients(address[] calldata _list) external onlyContract {
    for (uint256 i; i < _list.length; i++) {
      require(_list[i] != address(0), "SafeGuard: ZeroAddress");
      isRecipient[msg.sender][_list[i]] = true;
      emit RecipientSet(msg.sender, _list[i], true);
    }
  }

  function removeRecipient(address _recipient) external onlyContract {
    require(isRecipient[msg.sender][_recipient], "SafeGuard: InvalidRecipient");
    isRecipient[msg.sender][_recipient] = false;
    emit RecipientSet(msg.sender, _recipient, false);
  }

  function setCap(address _token, uint256 _amount) external onlyContract {
    cap[msg.sender][_token] = _amount;
    emit CapSet(msg.sender, _token, _amount);
  }

  function setRule(address _target, bytes4 _selector, uint8 _tier, uint248 _recipientWords) external onlyContract {
    require(_tier == PAUSE || _tier == ROUTINE, "SafeGuard: InvalidTier");
    require(_target != address(0) && _target != msg.sender && _target != address(this), "SafeGuard: InvalidTarget");
    require(!_denied(_selector), "SafeGuard: DeniedSelector");
    rules[msg.sender][_target][_selector] = Rule(_tier, _recipientWords);
    emit RuleSet(msg.sender, _target, _selector, _tier, _recipientWords);
  }

  function removeRule(address _target, bytes4 _selector) external onlyContract {
    require(rules[msg.sender][_target][_selector].tier != 0, "SafeGuard: InvalidRule");
    delete rules[msg.sender][_target][_selector];
    emit RuleSet(msg.sender, _target, _selector, 0, 0);
  }

  function _denied(bytes4 s) private pure returns (bool) {
    return
      s == IDenied.upgradeTo.selector ||
      s == IDenied.upgradeToAndCall.selector ||
      s == IDenied.upgrade.selector ||
      s == IDenied.upgradeAndCall.selector ||
      s == IDenied.grantRole.selector ||
      s == IDenied.transferOwnership.selector ||
      s == IDenied.unpause.selector;
  }

  /* ============ Views ============ */

  function getVaultNonce(address _vault) external view returns (uint256) {
    return ISafe(_vault).nonce();
  }

  function executors(address _vault) external view returns (address[] memory) {
    return _executors[_vault].values();
  }

  function auditors(address _vault) external view returns (address[] memory) {
    return _auditors[_vault].values();
  }

  function isContract(address addr) internal view returns (bool) {
    uint size;
    assembly {
      size := extcodesize(addr)
    }
    return size > 0;
  }

  /* ============ Guard ============ */

  /**
   * @notice Called by the Safe contract before a transaction is executed.
   * @param msgSender Executor of the transaction.
   */
  function checkTransaction(
    address to,
    uint256 value,
    bytes calldata data,
    Enum.Operation operation,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    address payable refundReceiver,
    bytes memory,
    address msgSender
  ) external override {
    if (_executors[msg.sender].length() != 0) {
      require(_executors[msg.sender].contains(msgSender), "SafeGuard: NotExecutor");
    }
    // Safe pays (gasUsed + baseGas) * gasPrice of gasToken to refundReceiver when gasPrice > 0. Never allow it.
    require(gasPrice == 0, "SafeGuard: NoRefund");
    if (operation == Enum.Operation.DelegateCall) {
      require(delegateAllowed[to], "SafeGuard: DelegateCallBlocked");
    }
    if (_auditors[msg.sender].length() == 0) return;

    // pure nonce-burning rejection: self, empty, every field zero
    if (
      to == msg.sender &&
      value == 0 &&
      data.length == 0 &&
      operation == Enum.Operation.Call &&
      safeTxGas == 0 &&
      baseGas == 0 &&
      gasToken == address(0) &&
      refundReceiver == address(0)
    ) return;
    if (value == 0 && operation == Enum.Operation.Call && _exempt(to, data)) return;

    bytes32 hash = encodeTransactionData(
      to,
      value,
      data,
      operation,
      safeTxGas,
      baseGas,
      gasPrice,
      gasToken,
      refundReceiver,
      ISafe(msg.sender).nonce() - 1
    );
    _authorize(to, value, data, operation, hash);
    emit SafeTxData(
      to,
      value,
      data,
      uint8(operation),
      safeTxGas,
      baseGas,
      gasPrice,
      gasToken,
      refundReceiver,
      ISafe(msg.sender).nonce() - 1,
      hash
    );
  }

  /// @dev Escape calls on this guard, and a matured escape `setGuard` on the Safe, need no auditor approval.
  function _exempt(address to, bytes calldata data) private returns (bool) {
    if (data.length < 4) return false;
    bytes4 sel = bytes4(data[:4]);
    if (to == address(this)) {
      return
        (sel == this.proposeAuditorReplacement.selector && data.length == 68) ||
        ((sel == this.proposeGuardChange.selector || sel == this.cancelEscape.selector) && data.length == 36);
    }
    if (to == msg.sender && sel == IGuardManager.setGuard.selector && data.length == 36) {
      bytes32 id = guardEscapeId(_addr(data, 4));
      uint256 eta = escapeEta[msg.sender][id];
      if (eta != 0 && block.timestamp >= eta) {
        _consumeEscape(msg.sender, id);
        return true;
      }
    }
    return false;
  }

  function _authorize(address to, uint256 value, bytes calldata data, Enum.Operation operation, bytes32 hash) private {
    (uint8 tier, bool emergency) = operation == Enum.Operation.DelegateCall
      ? _classifyBatch(msg.sender, data)
      : _classify(msg.sender, to, value, data);
    emergency = emergency && tier == CRITICAL; // the emergency path only exists for Critical
    if (tier != PAUSE) _checkApproval(msg.sender, hash, tier, emergency);
    emit TxAuthorized(msg.sender, hash, tier, emergency);
  }

  function _checkApproval(address s, bytes32 hash, uint8 tier, bool emergency) private view {
    (uint256 c, uint256 first, uint256 second) = _count(s, approvals[s][hash]);
    require(c >= (tier == CONFIG ? 2 : 1), "SafeGuard: NotApproved");
    require(block.timestamp < first + HASH_TTL, "SafeGuard: Expired");
    if (tier == CONFIG) require(block.timestamp >= second + DELAY, "SafeGuard: Timelocked");
    else if (tier == CRITICAL && !(emergency && c == 2)) {
      require(block.timestamp >= first + DELAY, "SafeGuard: Timelocked");
    }
  }

  /* ============ Classification ============ */

  /// @dev multiSend(bytes) on MultiSendCallOnly: strictest inner tier, emergency only if every op allows it.
  function _classifyBatch(address s, bytes calldata data) private returns (uint8 t, bool e) {
    require(data.length >= 4 && bytes4(data[:4]) == IMultiSend.multiSend.selector, "SafeGuard: NotMultiSend");
    uint256 p = 4 + _word(data, 4);
    uint256 end = p + 32 + _word(data, p);
    p += 32;
    require(end <= data.length, "SafeGuard: BadBatch");
    e = true;
    while (p < end) {
      require(uint8(data[p]) == 0, "SafeGuard: InnerDelegateCall");
      address to = address(uint160(_word(data, p + 1) >> 96));
      uint256 v = _word(data, p + 21);
      uint256 len = _word(data, p + 53);
      bytes calldata inner = data[p + 85:p + 85 + len];
      p += 85 + len;
      // MultiSend 1.4.1 replaces to == 0 with address(this), i.e. the Safe
      if (to == address(0)) to = s;
      (uint8 ti, bool ei) = _classify(s, to, v, inner);
      if (ti > t) t = ti;
      e = e && ei;
    }
    require(p == end, "SafeGuard: BadBatch");
    if (t == 0) t = ROUTINE;
  }

  function _classify(address s, address to, uint256 value, bytes calldata data) private returns (uint8 t, bool e) {
    if (to == s) (t, e) = _selfCall(s, data);
    else if (to == address(this)) (t, e) = (CONFIG, false); // any change to the guard's own lists
    else if (data.length == 0) (t, e) = (value == 0 ? CRITICAL : 0, true);
    else if (data.length < 4) (t, e) = (CRITICAL, true);
    else (t, e) = _externalCall(s, to, data);
    if (value != 0 && to != s) {
      (uint8 vt, bool ve) = _spend(s, address(0), to, value);
      if (vt > t) t = vt;
      e = e && ve;
    }
  }

  function _selfCall(address s, bytes calldata data) private view returns (uint8, bool) {
    bytes4 sel = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
    if (sel == IOwnerManager.removeOwner.selector && data.length >= 100) {
      return (_word(data, 68) >= ISafe(s).getThreshold() ? CRITICAL : CONFIG, true);
    }
    if (sel == IOwnerManager.changeThreshold.selector && data.length >= 36) {
      return (_word(data, 4) >= ISafe(s).getThreshold() ? CRITICAL : CONFIG, true);
    }
    // swapOwner brings in a new key: Critical, never on the emergency path
    if (sel == IOwnerManager.swapOwner.selector) return (CRITICAL, false);
    return (CONFIG, false);
  }

  function _externalCall(address s, address to, bytes calldata data) private returns (uint8, bool) {
    bytes4 sel = bytes4(data[:4]);
    if (sel == ITokenOps.transfer.selector || sel == ITokenOps.approve.selector || sel == ITokenOps.increaseAllowance.selector) {
      if (data.length < 68) return (CRITICAL, true);
      uint256 amt = _word(data, 36);
      if (sel == ITokenOps.approve.selector && amt == 0) return (ROUTINE, true);
      return _spend(s, to, _addr(data, 4), amt);
    }
    if (sel == ITokenOps.transferFrom.selector) {
      if (data.length < 100) return (CRITICAL, true);
      return _spend(s, to, _addr(data, 36), _word(data, 68));
    }
    Rule memory rule = rules[s][to][sel];
    if (rule.tier == 0) return (CRITICAL, true);
    for (uint256 i; rule.recipientWords >> i != 0; i++) {
      if ((rule.recipientWords >> i) & 1 == 0) continue;
      if (data.length < 36 + 32 * i) return (CRITICAL, false);
      address r = _addr(data, 4 + 32 * i);
      if (r != s && !isRecipient[s][r]) return (CRITICAL, false);
    }
    return (rule.tier, true);
  }

  /// @dev Transfer / approval of `amt` of `token` to `r`. Within the daily cap it is Routine and counted.
  function _spend(address s, address token, address r, uint256 amt) private returns (uint8, bool) {
    if (r == s) return (ROUTINE, true);
    if (!isRecipient[s][r]) return (CRITICAL, false);
    uint256 day = block.timestamp / 1 days;
    uint256 used = spent[s][token][day];
    uint256 c = cap[s][token];
    if (used > c || amt > c - used) return (CRITICAL, true);
    spent[s][token][day] = used + amt;
    return (ROUTINE, true);
  }

  function _word(bytes calldata d, uint256 off) private pure returns (uint256) {
    require(off + 32 <= d.length, "SafeGuard: ShortData");
    return uint256(bytes32(d[off:off + 32]));
  }

  function _addr(bytes calldata d, uint256 off) private pure returns (address) {
    uint256 w = _word(d, off);
    require(w >> 160 == 0, "SafeGuard: DirtyAddress");
    return address(uint160(w));
  }

  /// @dev SafeTx struct hash (no EIP-712 domain) - the hash auditors approve. Same scheme as the previous SafeGuard.
  function encodeTransactionData(
    address to,
    uint256 value,
    bytes memory data,
    Enum.Operation operation,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    address refundReceiver,
    uint256 _nonce
  ) public pure returns (bytes32) {
    return
      keccak256(
        abi.encode(
          SAFE_TX_TYPEHASH,
          to,
          value,
          keccak256(data),
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          _nonce
        )
      );
  }

  /**
   * @notice Called by the Safe contract after a transaction is executed.
   * @dev No-op.
   */
  function checkAfterExecution(bytes32, bool) external view override {}
}
