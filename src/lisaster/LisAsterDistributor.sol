// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { ILisAsterDistributor } from "./interface/ILisAsterDistributor.sol";
import { ILisAsterStaking } from "./interface/ILisAsterStaking.sol";

/// @title LisAsterDistributor
/// @notice Cumulative-style Merkle distributor. Single overwrite-on-update root; leaves carry
///         each account's lifetime cumulative entitlement, and users claim
///         `cumulative - claimed` deltas with the latest proof in one call.
///
///         Root rotation is two-step and time-locked: BOT stages a candidate via
///         `setPendingMerkleRoot`, then promotes it via `acceptMerkleRoot` after
///         `waitingPeriod` elapses. MANAGER holds the veto: it may
///         `revokePendingMerkleRoot` at any time while a pending root exists (both
///         during the wait and after, as long as BOT has not yet called `acceptMerkleRoot`).
contract LisAsterDistributor is
  ILisAsterDistributor,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  UUPSUpgradeable
{
  using SafeERC20 for IERC20;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant BOT = keccak256("BOT");

  /// @notice Hard floor on the time-lock window. Admin cannot configure a shorter window —
  ///         this guarantees MANAGER always has at least 6 hours to detect and `revokePendingMerkleRoot`
  ///         a malicious or wrong root staged by BOT.
  uint256 public constant MIN_WAITING_PERIOD = 6 hours;

  /* IMMUTABLE-LIKE (set once in initialize) */
  address public lisAster;
  address public staking;
  address public rewards;

  /* MERKLE STATE */
  bytes32 public merkleRoot;
  uint256 public merkleRootUpdatedAt;
  uint256 public totalAllocated; // Sum of cumulativeAmount across leaves of the current root

  /* ACCOUNTING */
  uint256 public totalNotified; // Lifetime inflow (incremented by Rewards.distributeRewards)
  uint256 public totalClaimed; // Lifetime amount already claimed
  mapping(address => uint256) public claimed; // Per-account lifetime claimed amount

  /* PENDING ROOT (appended to preserve UUPS storage layout) */
  bytes32 public pendingMerkleRoot;
  uint256 public pendingTotalAllocated;
  uint256 public lastSetTime;
  uint256 public waitingPeriod;

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  function initialize(
    address admin,
    address manager,
    address bot,
    address pauser,
    address lisAster_,
    address staking_,
    address rewards_,
    uint256 waitingPeriod_
  ) external initializer {
    require(admin != address(0), "admin is zero");
    require(manager != address(0), "manager is zero");
    require(bot != address(0), "bot is zero");
    require(pauser != address(0), "pauser is zero");
    require(lisAster_ != address(0), "lisAster is zero");
    require(staking_ != address(0), "staking is zero");
    require(rewards_ != address(0), "rewards is zero");
    require(waitingPeriod_ >= MIN_WAITING_PERIOD, "waitingPeriod too short");

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);
    _grantRole(PAUSER, pauser);

    lisAster = lisAster_;
    staking = staking_;
    rewards = rewards_;
    waitingPeriod = waitingPeriod_;
  }

  /* RECORD INFLOW */
  /// @notice Pulls `amount` lisAster from Rewards via transferFrom and bumps `totalNotified`.
  /// @dev Rewards must `forceApprove(distributor, amount)` before this call.
  function notifyRewards(uint256 amount) external override whenNotPaused nonReentrant {
    require(msg.sender == rewards, "not rewards");
    require(amount > 0, "zero amount");
    IERC20(lisAster).safeTransferFrom(msg.sender, address(this), amount);
    totalNotified += amount;
    emit Notified(amount);
  }

  /* MERKLE ROOT — STAGE / ACCEPT / REVOKE */
  /// @notice Stage a candidate root. BOT-only. Validates the candidate at stage time so that
  ///         a later `acceptMerkleRoot` only has to enforce the time lock. Re-staging
  ///         overwrites any prior pending root and resets the wait clock.
  function setPendingMerkleRoot(bytes32 root, uint256 newTotalAllocated) external override onlyRole(BOT) {
    require(root != bytes32(0), "zero root");
    require(newTotalAllocated >= totalAllocated, "allocated decrease");
    require(newTotalAllocated <= totalNotified, "exceeds notified");
    pendingMerkleRoot = root;
    pendingTotalAllocated = newTotalAllocated;
    lastSetTime = block.timestamp;
    emit SetPendingMerkleRoot(root, newTotalAllocated, block.timestamp);
  }

  /// @notice Promote the staged pending root to live. BOT-only, callable once
  ///         `block.timestamp >= lastSetTime + waitingPeriod`. The time-lock gives MANAGER
  ///         a window to `revokePendingMerkleRoot` if the staged root looks wrong.
  function acceptMerkleRoot() external override onlyRole(BOT) {
    bytes32 root = pendingMerkleRoot;
    require(root != bytes32(0), "no pending root");
    require(block.timestamp >= lastSetTime + waitingPeriod, "waiting period");

    uint256 newTotalAllocated = pendingTotalAllocated;
    // Defense-in-depth: re-validate the invariants stage-time enforced. Both should still
    // hold (totalNotified is monotone non-decreasing, totalAllocated is unchanged between
    // stage and accept), but a future change that breaks either should be caught here.
    require(newTotalAllocated >= totalAllocated, "allocated decrease");
    require(newTotalAllocated <= totalNotified, "exceeds notified");

    merkleRoot = root;
    merkleRootUpdatedAt = block.timestamp;
    totalAllocated = newTotalAllocated;

    pendingMerkleRoot = bytes32(0);
    pendingTotalAllocated = 0;
    lastSetTime = 0;

    emit AcceptMerkleRoot(root, newTotalAllocated, block.timestamp);
  }

  /// @notice Discard the staged pending root. MANAGER-only escape hatch for a wrong stage.
  function revokePendingMerkleRoot() external override onlyRole(MANAGER) {
    bytes32 root = pendingMerkleRoot;
    require(root != bytes32(0), "no pending root");
    pendingMerkleRoot = bytes32(0);
    pendingTotalAllocated = 0;
    lastSetTime = 0;
    emit RevokePendingMerkleRoot(root);
  }

  /// @notice Tune the time-lock window. Admin-only. Floored at `MIN_WAITING_PERIOD` so that
  ///         MANAGER's revoke window can never be configured below the safety threshold.
  ///         Disallowed while a pending root is in flight: otherwise lowering the window
  ///         would implicitly shrink MANAGER's veto time on the currently staged root.
  ///         If the admin needs to change the period mid-flight, revoke the pending root first.
  function changeWaitingPeriod(uint256 newWaitingPeriod) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(pendingMerkleRoot == bytes32(0), "pending root exists");
    require(newWaitingPeriod >= MIN_WAITING_PERIOD, "waitingPeriod too short");
    waitingPeriod = newWaitingPeriod;
    emit WaitingPeriodUpdated(newWaitingPeriod);
  }

  /* USER CLAIM */
  /// @notice Permissionless: any caller may trigger a claim for `account`. The proof binds
  ///         the payout destination to `account`, so caller substitution cannot redirect funds.
  function claim(
    address account,
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) external override whenNotPaused nonReentrant {
    require(account != address(0), "zero account");
    uint256 payable_ = _consume(account, cumulativeAmount, proof);
    IERC20(lisAster).safeTransfer(account, payable_);
    emit Claimed(account, payable_, cumulativeAmount);
  }

  /// @notice Self-only: `msg.sender` is the implicit recipient. Unlike `claim`, this entry
  ///         point materially changes the caller's position (locks the proceeds in staking),
  ///         so it does not accept a third-party `account` argument at all.
  function claimAndStake(
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) external override whenNotPaused nonReentrant {
    uint256 payable_ = _consume(msg.sender, cumulativeAmount, proof);
    IERC20(lisAster).forceApprove(staking, payable_);
    ILisAsterStaking(staking).stakeFor(msg.sender, payable_);
    IERC20(lisAster).forceApprove(staking, 0);
    emit ClaimedAndStaked(msg.sender, payable_, cumulativeAmount);
  }

  /* VIEW */
  function claimable(
    address account,
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) external view override returns (uint256) {
    if (merkleRoot == bytes32(0)) return 0;
    bytes32 leaf = keccak256(abi.encode(block.chainid, account, lisAster, cumulativeAmount));
    if (MerkleProof.processProofCalldata(proof, leaf) != merkleRoot) return 0;
    if (cumulativeAmount <= claimed[account]) return 0;
    return cumulativeAmount - claimed[account];
  }

  /* INTERNAL */
  function _consume(
    address account,
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) internal returns (uint256 payable_) {
    require(merkleRoot != bytes32(0), "no root");
    bytes32 leaf = keccak256(abi.encode(block.chainid, account, lisAster, cumulativeAmount));
    require(MerkleProof.verifyCalldata(proof, merkleRoot, leaf), "invalid proof");

    uint256 already = claimed[account];
    require(cumulativeAmount > already, "nothing to claim");
    payable_ = cumulativeAmount - already;
    require(totalClaimed + payable_ <= totalAllocated, "exceeds allocated");
    claimed[account] = cumulativeAmount;
    totalClaimed += payable_;
  }

  /* ADMIN */
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(PAUSER) {
    _unpause();
  }

  /// @notice Escape hatch for stuck or mis-routed tokens (e.g. tokens accidentally sent to this
  ///         contract, or lisAster that needs to be evacuated). Funds are sent to the MANAGER
  ///         caller. Does not adjust accounting, so if lisAster is withdrawn the team must
  ///         restage `totalNotified`/`totalAllocated` (or upgrade) before normal claims resume.
  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    require(token != address(0), "zero token");
    require(amount > 0, "zero amount");
    IERC20(token).safeTransfer(msg.sender, amount);
    emit EmergencyWithdrawn(token, msg.sender, amount);
  }

  /* UUPS */
  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
