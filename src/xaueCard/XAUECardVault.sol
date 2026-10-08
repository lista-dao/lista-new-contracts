// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title XAUECardVault
 * @notice On-chain entry of the XAUE Gold Card. The contract itself is the credential token
 *         (CreditXAUT, 6 decimals, non-transferable, 1:1 with deposited XAUt). XAUE reads
 *         `balanceOf` to size the card's credit line.
 *
 *         Deposit: the user's XAUt is forwarded to the XAUE receiving address in the same transaction
 *         and CreditXAUT is minted for what arrived there. This contract never holds deposits; the
 *         only XAUt on its balance is what XAUE has repaid for withdrawal requests, so there is no
 *         sweep, no keeper task for transfers, and `withdrawQuota()` is simply balance minus claimable
 *         reservations.
 *
 *         Redeem: gated by an XAUE EIP-712 signature (user, amount, nonce, deadline). The credential
 *         is burned at request time and a withdrawal request is queued per user, in the same shape as
 *         RWAEarnPool / XAUTStaking. Once XAUE returns the XAUt to this contract, BOT marks the
 *         request claimable by (user, redeem nonce) and the user claims it by index; claimed requests
 *         are removed with swap-and-pop, so indices are not stable across claims but nonces are.
 *         Requests never expire and cannot be cancelled.
 *
 *         Liquidation: BOT executes the XAUE-signed list XAUE delivers. Each row burns the user's
 *         credential, needs its own XAUE signature and is replay-protected by its `liquidationId`.
 */
contract XAUECardVault is
  ERC20Upgradeable,
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  EIP712Upgradeable
{
  using SafeERC20 for IERC20;

  /* TYPES */
  enum Action {
    Deposit,
    Redeem,
    Claim
  }

  /// @dev Two storage slots: `amount`, then the packed (withdrawTime, nonce, claimable).
  struct WithdrawalRequest {
    uint256 amount; // XAUt / CreditXAUT amount, 6 decimals
    uint40 withdrawTime; // block time of requestRedeem; front-end derives the T-business-day window
    uint64 nonce; // redeem signature nonce; unique per user, the key BOT and XAUE address this request by
    bool claimable; // set by BOT once XAUE has repaid this request
  }

  struct LiquidationItem {
    address user;
    uint256 amount;
    bytes32 liquidationId; // XAUE liquidation reference, globally unique
  }

  /* VARIABLES */
  /// @notice XAUt (Tether Gold, 6 decimals)
  address public asset;
  /// @notice XAUE receiving address; every deposit is forwarded here
  address public receiver;
  /// @notice XAUE signing address (EOA or ERC-1271 contract), shared by Redeem and Seize
  address public signer;
  /// @notice CreditXAUT supply cap (6 decimals); 0 closes deposits
  uint256 public cap;
  /// @notice Minimum single deposit (6 decimals)
  uint256 public minDeposit;
  /// @notice XAUt already assigned to claimable requests and not yet claimed
  uint256 public reservedForClaims;
  /// @notice Amount burned into requests that are not yet claimable (monitoring / reconciliation)
  uint256 public totalPendingRedeem;
  /// @notice user => withdrawal requests (claimed ones are removed with swap-and-pop)
  mapping(address => WithdrawalRequest[]) private userWithdrawalRequests;
  /// @notice user => next redeem signature nonce (sequential)
  mapping(address => uint256) public nonces;
  /// @notice liquidationId => executed
  mapping(bytes32 => bool) public usedLiquidationIds;
  /// @notice per-action pause flags, independent of the global pause
  mapping(Action => bool) public actionPaused;

  uint256[40] private __gap;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant REDEEM_TYPEHASH =
    keccak256("Redeem(address user,uint256 amount,uint256 nonce,uint256 deadline)");
  bytes32 public constant LIQUIDATE_TYPEHASH =
    keccak256("Liquidate(address user,uint256 amount,bytes32 liquidationId)");

  /* EVENTS */
  event Deposited(address indexed user, uint256 amount);
  event Forwarded(address indexed receiver, uint256 amount);
  event RequestRedeem(address indexed user, uint256 idx, uint256 nonce, uint256 amount);
  event ClaimableWithdrawal(address indexed user, uint256 idx, uint256 nonce, uint256 amount);
  event ClaimWithdrawal(address indexed user, uint256 idx, uint256 nonce, uint256 amount);
  event Seized(address indexed user, uint256 amount, bytes32 indexed liquidationId);
  event SetReceiver(address receiver);
  event SetSigner(address signer);
  event SetCap(uint256 cap);
  event SetMinDeposit(uint256 minDeposit);
  event ActionPaused(Action indexed action, bool paused);
  event WithdrawExcess(address indexed to, uint256 amount);
  event RescueToken(address indexed token, address indexed to, uint256 amount);

  /* MODIFIERS */
  modifier whenActionNotPaused(Action action) {
    require(!actionPaused[action], "action paused");
    _;
  }

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  /**
   * @param _admin DEFAULT_ADMIN_ROLE (TimeLock): upgrades, receiver, signer, withdrawExcess
   * @param _manager MANAGER (multisig): cap, minDeposit, unpause, rescue
   * @param _pauser PAUSER: pause
   * @param _bot BOT: markClaimable, seize
   * @param _asset XAUt
   * @param _receiver XAUE receiving address
   * @param _signer XAUE signing address
   * @param _cap Initial CreditXAUT supply cap (6 decimals)
   * @param _minDeposit Initial minimum deposit (6 decimals)
   */
  function initialize(
    address _admin,
    address _manager,
    address _pauser,
    address _bot,
    address _asset,
    address _receiver,
    address _signer,
    uint256 _cap,
    uint256 _minDeposit
  ) external initializer {
    require(_admin != address(0), "admin is zero");
    require(_manager != address(0), "manager is zero");
    require(_pauser != address(0), "pauser is zero");
    require(_bot != address(0), "bot is zero");
    require(_asset != address(0), "asset is zero");
    require(_receiver != address(0), "receiver is zero");
    require(_signer != address(0), "signer is zero");

    __ERC20_init("Credit XAUt", "CreditXAUT");
    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __EIP712_init("XAUECardVault", "1");

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);
    _grantRole(BOT, _bot);

    asset = _asset;
    receiver = _receiver;
    signer = _signer;
    cap = _cap;
    minDeposit = _minDeposit;

    emit SetReceiver(_receiver);
    emit SetSigner(_signer);
    emit SetCap(_cap);
    emit SetMinDeposit(_minDeposit);
  }

  /* USER ENTRY POINTS */

  /**
   * @notice Forward `amount` of XAUt from the caller straight to the XAUE receiving address and mint
   *         the same amount of CreditXAUT to the caller. Minted to `msg.sender` only: XAUE binds the
   *         card to the depositing address. The credential is minted for what actually arrived at the
   *         receiver, so a token-level transfer fee can never over-mint.
   * @param amount XAUt amount to pull (6 decimals)
   */
  function deposit(uint256 amount) external whenNotPaused whenActionNotPaused(Action.Deposit) nonReentrant {
    require(amount > 0, "amount is zero");

    address to = receiver;
    uint256 before = IERC20(asset).balanceOf(to);
    IERC20(asset).safeTransferFrom(msg.sender, to, amount);
    uint256 received = IERC20(asset).balanceOf(to) - before;
    emit Forwarded(to, received);

    require(received > 0, "nothing received");
    require(received >= minDeposit, "below min deposit");
    require(totalSupply() + received <= cap, "exceeds cap");

    _mint(msg.sender, received);
    emit Deposited(msg.sender, received);
  }

  /**
   * @notice Burn `amount` of the caller's CreditXAUT against an XAUE signature and queue a withdrawal
   *         request. Not cancellable: XAUE freezes the matching credit line when it signs.
   * @param amount CreditXAUT to burn (6 decimals)
   * @param deadline Signature expiry (unix seconds)
   * @param sig XAUE EIP-712 signature over Redeem(msg.sender, amount, nonces[msg.sender], deadline)
   */
  function requestRedeem(
    uint256 amount,
    uint256 deadline,
    bytes calldata sig
  ) external whenNotPaused whenActionNotPaused(Action.Redeem) nonReentrant {
    require(amount > 0, "amount is zero");
    require(block.timestamp <= deadline, "signature expired");
    require(balanceOf(msg.sender) >= amount, "insufficient balance");

    uint256 nonce = nonces[msg.sender]++;
    bytes32 digest = hashRedeem(msg.sender, amount, nonce, deadline);
    require(SignatureChecker.isValidSignatureNow(signer, digest, sig), "invalid signature");

    _burn(msg.sender, amount);

    WithdrawalRequest[] storage requests = userWithdrawalRequests[msg.sender];
    requests.push(
      WithdrawalRequest({
        amount: amount,
        withdrawTime: uint40(block.timestamp),
        nonce: uint64(nonce),
        claimable: false
      })
    );
    totalPendingRedeem += amount;

    emit RequestRedeem(msg.sender, requests.length - 1, nonce, amount);
  }

  /**
   * @notice Claim a claimable withdrawal request belonging to `msg.sender`. Swap-and-pop: the last
   *         request moves into `idx`, so callers must re-read `getUserWithdrawalRequests` after every
   *         claim instead of caching indices.
   * @param idx Index into the caller's request array
   */
  function claimWithdraw(uint256 idx) external whenNotPaused whenActionNotPaused(Action.Claim) nonReentrant {
    WithdrawalRequest[] storage requests = userWithdrawalRequests[msg.sender];
    require(idx < requests.length, "invalid index");
    WithdrawalRequest memory request = requests[idx];
    require(request.claimable, "not claimable yet");

    requests[idx] = requests[requests.length - 1];
    requests.pop();
    reservedForClaims -= request.amount;

    IERC20(asset).safeTransfer(msg.sender, request.amount);
    emit ClaimWithdrawal(msg.sender, idx, request.nonce, request.amount);
  }

  /* BOT */

  /**
   * @notice Mark withdrawal requests claimable once XAUE has returned their XAUt. Requests are
   *         addressed by (user, redeem nonce), never by index: a user's claimWithdraw can move a
   *         pending request to another slot, but cannot remove it, so the scan always finds it and a
   *         concurrent claim can neither mis-target nor revert this call. The nonce is what XAUE
   *         signed and what RequestRedeem emitted, so BOT, XAUE and the backend reconcile on one key.
   *         Each request needs its full amount available in `withdrawQuota()`, so BOT can only decide the
   *         ordering, never release a request that is not funded. Deliberately not pause-gated so
   *         requests are ready the moment claims are re-enabled.
   */
  function markClaimable(
    address[] calldata users,
    uint256[] calldata redeemNonces
  ) external onlyRole(BOT) nonReentrant {
    require(users.length == redeemNonces.length, "length mismatch");
    for (uint256 i = 0; i < users.length; i++) {
      WithdrawalRequest[] storage requests = userWithdrawalRequests[users[i]];
      uint256 idx = _findPending(requests, redeemNonces[i]);
      WithdrawalRequest storage request = requests[idx];
      require(withdrawQuota() >= request.amount, "insufficient repayment");

      request.claimable = true;
      reservedForClaims += request.amount;
      totalPendingRedeem -= request.amount;

      emit ClaimableWithdrawal(users[i], idx, redeemNonces[i], request.amount);
    }
  }

  /**
   * @notice Execute XAUE-signed liquidation rows: burn each user's credential. Driven by BOT from the
   *         list XAUE delivers; every row still needs XAUE's signature, so neither party can burn a
   *         credential alone. One signature per row so a disputed row can be dropped without
   *         re-signing the rest. A row whose user no longer holds the amount reverts the whole call;
   *         that is an XAUE-side process error to fix off-chain rather than clamp on-chain. Gated by
   *         the global pause only: an automated burn path needs a brake during an incident, and the
   *         per-action flags are reserved for user entry points.
   */
  function liquidate(
    LiquidationItem[] calldata items,
    bytes[] calldata sigs
  ) external onlyRole(BOT) whenNotPaused nonReentrant {
    require(items.length == sigs.length, "length mismatch");
    for (uint256 i = 0; i < items.length; i++) {
      LiquidationItem calldata item = items[i];
      require(!usedLiquidationIds[item.liquidationId], "liquidation already executed");
      require(item.amount > 0, "amount is zero");
      require(balanceOf(item.user) >= item.amount, "insufficient balance");

      bytes32 digest = hashLiquidate(item.user, item.amount, item.liquidationId);
      require(SignatureChecker.isValidSignatureNow(signer, digest, sigs[i]), "invalid signature");

      usedLiquidationIds[item.liquidationId] = true;
      _burn(item.user, item.amount);

      emit Seized(item.user, item.amount, item.liquidationId);
    }
  }

  /* MANAGER */

  function setCap(uint256 _cap) external onlyRole(MANAGER) {
    require(_cap != cap, "same cap");
    cap = _cap;
    emit SetCap(_cap);
  }

  function setMinDeposit(uint256 _minDeposit) external onlyRole(MANAGER) {
    require(_minDeposit != minDeposit, "same minDeposit");
    minDeposit = _minDeposit;
    emit SetMinDeposit(_minDeposit);
  }

  /// @notice Rescue a token other than the asset. The asset can only leave through claimWithdraw and
  ///         `withdrawExcess`, so no single role can move user XAUt to an arbitrary address.
  function rescueToken(address token, uint256 amount, address to) external onlyRole(MANAGER) {
    require(token != asset, "cannot rescue asset");
    require(to != address(0), "to is zero");
    require(amount > 0, "amount is zero");
    IERC20(token).safeTransfer(to, amount);
    emit RescueToken(token, to, amount);
  }

  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function unpauseAction(Action action) external onlyRole(MANAGER) {
    require(actionPaused[action], "action not paused");
    actionPaused[action] = false;
    emit ActionPaused(action, false);
  }

  /* PAUSER */

  /// @notice Global pause, compatible with EmergencySwitchHub. Stops deposit, redeem, claim and seize.
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function pauseAction(Action action) external onlyRole(PAUSER) {
    require(!actionPaused[action], "action already paused");
    actionPaused[action] = true;
    emit ActionPaused(action, true);
  }

  /* ADMIN */

  /// @notice Change the XAUE receiving address. Takes effect from the next deposit; nothing held
  ///         here moves, because nothing deposited is ever held here.
  function setReceiver(address _receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_receiver != address(0), "receiver is zero");
    require(_receiver != receiver, "same receiver");
    receiver = _receiver;
    emit SetReceiver(_receiver);
  }

  /// @notice Change the XAUE signing address. Every signature issued by the previous signer stops
  ///         verifying immediately.
  function setSigner(address _signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_signer != address(0), "signer is zero");
    require(_signer != signer, "same signer");
    signer = _signer;
    emit SetSigner(_signer);
  }

  /// @notice Move XAUt that belongs to nobody on-chain (an XAUE over-repayment or a stray transfer).
  ///         Bounded by `withdrawQuota()`, so claimable requests are untouchable.
  function withdrawExcess(uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
    require(to != address(0), "to is zero");
    require(amount > 0, "amount is zero");
    require(amount <= withdrawQuota(), "exceeds withdraw quota");
    IERC20(asset).safeTransfer(to, amount);
    emit WithdrawExcess(to, amount);
  }

  /* VIEWS */

  /// @notice XAUt received from XAUE and not yet assigned to a request: the same meaning as
  ///         RWAEarnPool.withdrawQuota, derived from the balance here instead of kept as a counter,
  ///         so it also counts any XAUt sent to this contract by mistake (recoverable via withdrawExcess).
  function withdrawQuota() public view returns (uint256) {
    uint256 balance = IERC20(asset).balanceOf(address(this));
    return balance > reservedForClaims ? balance - reservedForClaims : 0;
  }

  function hashRedeem(address user, uint256 amount, uint256 nonce, uint256 deadline) public view returns (bytes32) {
    return _hashTypedDataV4(keccak256(abi.encode(REDEEM_TYPEHASH, user, amount, nonce, deadline)));
  }

  function hashLiquidate(address user, uint256 amount, bytes32 liquidationId) public view returns (bytes32) {
    return _hashTypedDataV4(keccak256(abi.encode(LIQUIDATE_TYPEHASH, user, amount, liquidationId)));
  }

  /// @notice Outstanding (unclaimed) withdrawal requests of `user`.
  function getUserWithdrawalRequests(address user) external view returns (WithdrawalRequest[] memory) {
    return userWithdrawalRequests[user];
  }

  /// @notice Number of outstanding withdrawal requests of `user`; shrinks as the user claims.
  function getUserWithdrawalRequestCount(address user) external view returns (uint256) {
    return userWithdrawalRequests[user].length;
  }

  /// @notice Paginated slice of `user`'s requests over [start, end); `end` is clamped to the length.
  ///         Indices are unstable across claims (swap-and-pop), so clients should key on content.
  function getUserWithdrawalRequests(
    address user,
    uint256 start,
    uint256 end
  ) external view returns (WithdrawalRequest[] memory page) {
    WithdrawalRequest[] storage requests = userWithdrawalRequests[user];
    uint256 len = requests.length;
    if (end > len) {
      end = len;
    }
    if (start >= end) {
      return new WithdrawalRequest[](0);
    }
    page = new WithdrawalRequest[](end - start);
    for (uint256 i = start; i < end; i++) {
      page[i - start] = requests[i];
    }
  }

  /// @notice 6 decimals, same unit as XAUt so 1 CreditXAUT == 1 XAUt with no conversion.
  function decimals() public pure override returns (uint8) {
    return 6;
  }

  /* CREDENTIAL: NON-TRANSFERABLE */

  function transfer(address, uint256) public pure override returns (bool) {
    revert("not transferable");
  }

  function transferFrom(address, address, uint256) public pure override returns (bool) {
    revert("not transferable");
  }

  function approve(address, uint256) public pure override returns (bool) {
    revert("not transferable");
  }

  /// @dev Only mint and burn may move balances, whatever path a future extension might add.
  function _update(address from, address to, uint256 value) internal override {
    require(from == address(0) || to == address(0), "not transferable");
    super._update(from, to, value);
  }

  /* INTERNAL */

  /// @dev Index of the pending request with this redeem nonce. Outstanding requests per user are
  ///      few (each one needed an XAUE signature), so a linear scan is cheaper than any index.
  function _findPending(WithdrawalRequest[] storage requests, uint256 nonce) internal view returns (uint256) {
    uint256 len = requests.length;
    for (uint256 i = 0; i < len; i++) {
      if (requests[i].nonce == nonce) {
        require(!requests[i].claimable, "already claimable");
        return i;
      }
    }
    revert("request not found");
  }

  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
