// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { IAsterVault } from "./interface/IAsterVault.sol";
import { ILisAsterDistributor } from "./interface/ILisAsterDistributor.sol";
import { ILisAsterStaking } from "./interface/ILisAsterStaking.sol";

/// @title LisAsterDistributor
/// @notice ASTER-denominated cumulative Merkle distributor. Holds ASTER, single overwrite-on-
///         accept root; leaves carry each account's lifetime cumulative entitlement in ASTER,
///         and users claim `cumulative - claimed` deltas with the latest proof in one call.
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
  /// @notice Reward token; payouts and Merkle leaves are denominated in this asset.
  address public asterToken;
  /// @notice lisAster proxy. Held transiently inside `claimAndStake` between `Vault.deposit`
  ///         and `Staking.stakeFor`.
  address public lisAster;
  /// @notice AsterVault proxy. `claimAndStake` calls `deposit(payable_, address(this))` to
  ///         convert ASTER to lisAster before staking.
  address public vault;
  /// @notice LisAsterStaking proxy. `claimAndStake` calls `stakeFor(msg.sender, payable_)`
  ///         to place the staked position on the user's behalf.
  address public staking;
  /// @notice The LisAsterRewards proxy authorised to call `notifyRewards`.
  address public rewards;

  /* MERKLE STATE */
  bytes32 public merkleRoot;
  uint256 public merkleRootUpdatedAt;
  uint256 public totalAllocated; // Sum of cumulativeAmount across leaves of the current root

  /* ACCOUNTING */
  uint256 public totalNotified; // Lifetime ASTER inflow (incremented by Rewards.distributeRewards)
  uint256 public totalClaimed; // Lifetime ASTER already claimed
  mapping(address => uint256) public claimed; // Per-account lifetime claimed amount

  /* PENDING ROOT */
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
  /// @dev Parameters bundled into a struct because the 10-argument signature blew the EVM
  ///      stack limit in `initialize`.
  struct InitParams {
    address admin;
    address manager;
    address bot;
    address pauser;
    address asterToken;
    address lisAster;
    address vault;
    address staking;
    address rewards;
    uint256 waitingPeriod;
  }

  function initialize(InitParams calldata p) external initializer {
    require(p.admin != address(0), "admin is zero");
    require(p.manager != address(0), "manager is zero");
    require(p.bot != address(0), "bot is zero");
    require(p.pauser != address(0), "pauser is zero");
    require(p.asterToken != address(0), "asterToken is zero");
    require(p.lisAster != address(0), "lisAster is zero");
    require(p.vault != address(0), "vault is zero");
    require(p.staking != address(0), "staking is zero");
    require(p.rewards != address(0), "rewards is zero");
    require(p.waitingPeriod >= MIN_WAITING_PERIOD, "waitingPeriod too short");

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
    _grantRole(MANAGER, p.manager);
    _grantRole(BOT, p.bot);
    _grantRole(PAUSER, p.pauser);

    asterToken = p.asterToken;
    lisAster = p.lisAster;
    vault = p.vault;
    staking = p.staking;
    rewards = p.rewards;
    waitingPeriod = p.waitingPeriod;
  }

  /* RECORD INFLOW */
  /// @notice Pulls `amount` ASTER from Rewards via transferFrom and bumps `totalNotified`.
  /// @dev Rewards must `forceApprove(distributor, amount)` before this call.
  function notifyRewards(uint256 amount) external override whenNotPaused nonReentrant {
    require(msg.sender == rewards, "not rewards");
    require(amount > 0, "zero amount");
    IERC20(asterToken).safeTransferFrom(msg.sender, address(this), amount);
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
    IERC20(asterToken).safeTransfer(account, payable_);
    emit Claimed(account, payable_, cumulativeAmount);
  }

  /// @notice Self-only: `msg.sender` is the implicit recipient. Routes ASTER through
  ///         `Vault.deposit` (mints lisAster to this contract) and then `Staking.stakeFor`
  ///         (places the position under `msg.sender`). Reverts if the payable amount is
  ///         below `Vault.minDeposit` — fall back to `claim` for small balances.
  function claimAndStake(
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) external override whenNotPaused nonReentrant {
    uint256 payable_ = _consume(msg.sender, cumulativeAmount, proof);

    IERC20(asterToken).forceApprove(vault, payable_);
    IAsterVault(vault).deposit(payable_, address(this));

    IERC20(lisAster).forceApprove(staking, payable_);
    ILisAsterStaking(staking).stakeFor(msg.sender, payable_);

    emit ClaimedAndStaked(msg.sender, payable_, cumulativeAmount);
  }

  /* VIEW */
  function claimable(
    address account,
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) external view override returns (uint256) {
    if (merkleRoot == bytes32(0)) return 0;
    bytes32 leaf = keccak256(abi.encode(block.chainid, account, asterToken, cumulativeAmount));
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
    bytes32 leaf = keccak256(abi.encode(block.chainid, account, asterToken, cumulativeAmount));
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
  ///         contract, or ASTER that needs to be evacuated). Funds are sent to the MANAGER
  ///         caller. Does not adjust accounting, so if ASTER is withdrawn the team must
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
