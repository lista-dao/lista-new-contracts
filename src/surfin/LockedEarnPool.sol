// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CreditFundBase } from "./CreditFundBase.sol";

/**
 * @title LockedEarnPool
 * @notice Locked (term) product of the Surfin Credit Fund (e.g. 3M+, 6M+).
 *
 * Each deposit joins a cohort (issuance batch). The cohort carries the
 * settlement-aligned interest-start and maturity dates, injected
 * off-chain by the manager and bounded on-chain, so every position in a batch
 * shares the same schedule and one update covers them all. Early redemption
 * (partial allowed) forfeits all interest and, if made within PENALTY_WINDOW of
 * deposit, deducts a flat `penaltyRate` on the redeemed principal; past the
 * window the full principal is returned. Interest (base + loyalty) is distributed
 * off-pool via the cumulative Merkle InterestDistributor; renewal rolls the
 * principal only into a fresh cohort.
 */
contract LockedEarnPool is CreditFundBase {
  using SafeERC20 for IERC20;

  /* STRUCTS */
  // a single locked position (dates live on the referenced cohort)
  struct Position {
    uint256 principal; // principal amount
    uint256 cohortId; // issuance batch this position belongs to
    uint256 depositTime; // position creation time; early-redeem penalty window anchor
    bool autoRenew; // roll principal into a new term on maturity
    bool closed; // position terminated (redeemed / matured-out / renewed)
  }

  // an issuance batch (cohort). Dates are settlement-aligned and injected
  // off-chain by the manager; all positions in a cohort share them, so one
  // update covers the whole batch ("same batch, same maturity").
  struct Cohort {
    uint256 termDays; // nominal lock term in days (bounds the maturity)
    uint256 depositDeadline; // deposits accepted until this time
    uint256 maturityTime; // maturity date (settlement-aligned)
    bool enabled; // open for deposit
  }

  /* CONSTANTS */
  // early-redeem penalty applies to redemptions within this window from deposit
  uint256 public constant PENALTY_WINDOW = 30 days;
  // guardrail: highest early-redeem penalty rate the manager can set (1e18 = 100%)
  uint256 public constant MAX_PENALTY_RATE = 0.1 ether;
  // guardrail: maturity can be at most this far past the nominal term end
  uint256 public constant MAX_ALIGN_WINDOW = 31 days;
  // auto-renew is locked within this window before maturity (T-32 checkpoint)
  uint256 public constant AUTO_RENEW_LOCK_WINDOW = 32 days;

  /* VARIABLES */
  // user => positions
  mapping(address => Position[]) internal userPositions;
  // total principal across all open positions
  uint256 public totalPrincipalAmount;
  // cohort id => issuance batch config
  mapping(uint256 => Cohort) public cohorts;
  // early-redeem penalty rate on redeemed principal, 1e18 (e.g. 0.008e18 = 0.8%)
  uint256 public penaltyRate;

  /* EVENTS */
  event LockedDeposit(address indexed user, uint256 posId, uint256 cohortId, uint256 amount, uint256 maturityTime);
  event RequestEarlyRedeem(address indexed user, uint256 posId, uint256 principal, uint256 batchId, uint256 payout);
  event RequestMaturityWithdraw(address indexed user, uint256 posId, uint256 principal, uint256 batchId);
  event RenewPosition(address indexed user, uint256 oldPosId, uint256 newPosId, uint256 principal);
  event Reinvest(address indexed user, uint256 idx, uint256 newCohortId, uint256 newPosId, uint256 principal);
  event ToggleAutoRenew(address indexed user, uint256 posId, bool autoRenew);
  event SetCohort(uint256 cohortId, uint256 termDays, uint256 depositDeadline, uint256 maturityTime, bool enabled);
  event SetPenaltyRate(uint256 penaltyRate);

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  function initialize(
    address _admin,
    address _manager,
    address _pauser,
    address _bot,
    address _asset,
    address _adapter,
    string memory _name,
    string memory _symbol
  ) external initializer {
    __CreditFundBase_init(_admin, _manager, _pauser, _bot, _asset, _adapter, _name, _symbol);
    penaltyRate = 0.008 ether; // 0.8% default early-redeem penalty
  }

  /* EXTERNAL FUNCTIONS */
  /**
   * @dev deposit into a cohort; funds go straight to the adapter.
   * @param cohortId the issuance batch id
   * @param amount the amount of asset to deposit
   * @param receiver the owner of the new position
   * @param autoRenew whether to auto-renew the position on maturity
   */
  function deposit(
    uint256 cohortId,
    uint256 amount,
    address receiver,
    bool autoRenew
  ) external whenNotPaused whenDepositNotPaused nonReentrant {
    Cohort memory c = cohorts[cohortId];
    require(c.enabled, "cohort not enabled");
    require(block.timestamp <= c.depositDeadline, "deposit window closed");
    require(amount > 0, "amount is zero");
    require(receiver != address(0), "receiver is zero address");
    require(amount >= minDeposit, "deposit below minimum");

    userPositions[receiver].push(
      Position({
        principal: amount,
        cohortId: cohortId,
        depositTime: block.timestamp,
        autoRenew: autoRenew,
        closed: false
      })
    );
    totalPrincipalAmount += amount;

    IERC20(asset).safeTransferFrom(msg.sender, adapter, amount);

    emit LockedDeposit(receiver, userPositions[receiver].length - 1, cohortId, amount, c.maturityTime);
  }

  /**
   * @dev request early redemption of `amount` principal from a position (partial
   *      allowed). All interest is forfeited; if redeemed within PENALTY_WINDOW of
   *      deposit, a flat `penaltyRate` on the redeemed principal is deducted. The
   *      payout enters the batch queue. The position stays open with reduced
   *      principal, or is closed once fully redeemed.
   * @param posId the caller's position id
   * @param amount the principal amount to early-redeem
   */
  function requestEarlyRedeem(uint256 posId, uint256 amount) external whenNotPaused whenDepositNotPaused nonReentrant {
    Position storage pos = userPositions[msg.sender][posId];
    require(pos.principal > 0 && !pos.closed, "invalid position");
    require(amount > 0 && amount <= pos.principal, "invalid amount");

    // min-withdraw floor with dust exit: a sub-min redeem must clear the position
    _checkMinWithdraw(amount, pos.principal);

    uint256 cohortId = pos.cohortId;
    require(block.timestamp < cohorts[cohortId].maturityTime, "already matured");

    uint256 payout = _earlyRedeemPayout(pos.depositTime, amount);

    pos.principal -= amount;
    if (pos.principal == 0) {
      pos.closed = true;
    }
    totalPrincipalAmount -= amount;

    _consumeDailyLimit(msg.sender, payout);
    uint256 batchId = _enqueueWithdraw(msg.sender, payout, cohortId);

    emit RequestEarlyRedeem(msg.sender, posId, amount, batchId, payout);
  }

  /**
   * @dev request withdraw of a matured position (only when not auto-renewing).
   *      Principal enters the batch queue. No daily limit is applied to matured
   *      principal.
   * @param posId the caller's position id
   */
  function requestMaturityWithdraw(uint256 posId) external whenNotPaused nonReentrant {
    _requestMaturityWithdraw(msg.sender, posId);
  }

  /**
   * @dev BOT enqueues matured positions on behalf of users. The UI does not expose
   *      a maturity-withdraw button, so users would otherwise never queue their
   *      matured principal; the settlement-day job (BOT) does it for them and the
   *      platform covers the gas. Run early each month once positions have matured.
   *      Each entry follows the same rules as the user path (matured, not
   *      auto-renewing); withdrawTime is the BOT call time (after maturity, so it
   *      reads as a normal redemption). Reverts atomically on any invalid entry so
   *      a BOT list-building bug surfaces instead of being silently skipped.
   * @param users the position owners
   * @param posIds the matching position ids
   */
  function batchRequestMaturityWithdraw(
    address[] calldata users,
    uint256[] calldata posIds
  ) external whenNotPaused onlyRole(BOT) nonReentrant {
    require(users.length == posIds.length, "length mismatch");
    for (uint256 i = 0; i < users.length; i++) {
      _requestMaturityWithdraw(users[i], posIds[i]);
    }
  }

  /**
   * @dev shared matured-withdraw path: close the position and queue its principal.
   *      Called for the owner (user path) or on their behalf (BOT batch path).
   * @param user the position owner
   * @param posId the position id
   */
  function _requestMaturityWithdraw(address user, uint256 posId) internal {
    Position storage pos = userPositions[user][posId];
    require(pos.principal > 0 && !pos.closed, "invalid position");
    require(block.timestamp >= cohorts[pos.cohortId].maturityTime, "not matured");
    require(!pos.autoRenew, "auto renew on");

    uint256 principal = pos.principal;
    uint256 cohortId = pos.cohortId;
    pos.closed = true;
    totalPrincipalAmount -= principal;

    uint256 batchId = _enqueueWithdraw(user, principal, cohortId);

    emit RequestMaturityWithdraw(user, posId, principal, batchId);
  }

  /**
   * @dev toggle auto-renew for a position. Enforced on-chain to be locked from the
   *      T-30 checkpoint: no changes are allowed within AUTO_RENEW_LOCK_WINDOW of
   *      maturity, so the settlement-day job can rely on a stable auto-renew flag.
   * @param posId the caller's position id
   */
  function toggleAutoRenew(uint256 posId) external whenNotPaused {
    Position storage pos = userPositions[msg.sender][posId];
    require(pos.principal > 0 && !pos.closed, "invalid position");
    require(block.timestamp + AUTO_RENEW_LOCK_WINDOW < cohorts[pos.cohortId].maturityTime, "auto renew locked (T-30)");

    pos.autoRenew = !pos.autoRenew;
    emit ToggleAutoRenew(msg.sender, posId, pos.autoRenew);
  }

  /**
   * @dev roll a matured auto-renew position's principal into a fresh cohort.
   *      Only principal is rolled (interest is distributed separately). Renewal
   *      is limited to one term: the new position has auto-renew forced off.
   *      Driven by the settlement-day job (BOT).
   * @param user the position owner
   * @param posId the matured position id
   * @param newCohortId the cohort to renew into
   */
  function renewPosition(address user, uint256 posId, uint256 newCohortId) external onlyRole(BOT) nonReentrant {
    Position storage pos = userPositions[user][posId];
    require(pos.principal > 0 && !pos.closed, "invalid position");
    require(pos.autoRenew, "auto renew off");
    require(block.timestamp >= cohorts[pos.cohortId].maturityTime, "not matured");

    Cohort memory c = cohorts[newCohortId];
    require(c.enabled, "cohort not enabled");

    uint256 principal = pos.principal;
    pos.closed = true;

    userPositions[user].push(
      Position({
        principal: principal,
        cohortId: newCohortId,
        depositTime: block.timestamp,
        autoRenew: false,
        closed: false
      })
    );
    // totalPrincipalAmount unchanged: principal moves from old to new position

    emit RenewPosition(user, posId, userPositions[user].length - 1, principal);
  }

  /**
   * @dev one-click reinvest: roll an already-funded (claimable) withdrawal payout
   *      into a fresh locked cohort instead of claiming it to the wallet. Offered on
   *      the position page after settlement-day funding (finishWithdraw), as the peer
   *      alternative to claimWithdraw. Only principal is rolled (interest is
   *      distributed separately). Renewal is limited to one term: the new position
   *      has auto-renew forced off. Blocked during wind-down (whenDepositNotPaused),
   *      which leaves claimWithdraw as the only exit.
   * @param idx the caller's confirmed (funded) withdrawal request index
   * @param newCohortId the cohort to reinvest into
   */
  function reinvest(uint256 idx, uint256 newCohortId) external whenNotPaused whenDepositNotPaused nonReentrant {
    Cohort memory c = cohorts[newCohortId];
    require(c.enabled, "cohort not enabled");
    require(block.timestamp <= c.depositDeadline, "deposit window closed");

    // consume the funded payout (same gate as claimWithdraw); its cash was pushed
    // into the pool by finishWithdraw and is sitting here now
    uint256 principal = _consumeConfirmedWithdraw(msg.sender, idx);
    require(principal >= minDeposit, "deposit below minimum");

    // book the new position first (CEI: all state settled before the external transfer)
    userPositions[msg.sender].push(
      Position({
        principal: principal,
        cohortId: newCohortId,
        depositTime: block.timestamp,
        autoRenew: false,
        closed: false
      })
    );
    totalPrincipalAmount += principal;

    // return the funded cash to the adapter so reinvested principal follows the same
    // custody path as a fresh deposit
    IERC20(asset).safeTransfer(adapter, principal);

    emit Reinvest(msg.sender, idx, newCohortId, userPositions[msg.sender].length - 1, principal);
  }

  /* VIEWS */
  /// @inheritdoc CreditFundBase
  function totalPrincipal() external view override returns (uint256) {
    return totalPrincipalAmount;
  }

  function getUserPositions(address user) external view returns (Position[] memory) {
    return userPositions[user];
  }

  /**
   * @dev preview the early-redeem payout for `amount` principal of a position.
   */
  function previewEarlyRedeem(address user, uint256 posId, uint256 amount) external view returns (uint256) {
    Position memory pos = userPositions[user][posId];
    return _earlyRedeemPayout(pos.depositTime, amount);
  }

  /* MANAGER FUNCTIONS */
  /**
   * @dev create or adjust a cohort (issuance batch). Dates are injected off-chain
   *      but bounded on-chain: the maturity must land between the nominal term end
   *      (deposit deadline + term) and MAX_ALIGN_WINDOW past it. This guardrail
   *      keeps the manager from arbitrarily extending or shortening positions.
   * @param cohortId the cohort id
   * @param termDays nominal lock term in days
   * @param depositDeadline last time deposits are accepted into this cohort
   * @param maturityTime maturity date (settlement-aligned)
   * @param enabled whether the cohort is open for deposit
   */
  function setCohort(
    uint256 cohortId,
    uint256 termDays,
    uint256 depositDeadline,
    uint256 maturityTime,
    bool enabled
  ) external onlyRole(BOT) {
    require(termDays > 0, "term is zero");
    uint256 nominalEnd = depositDeadline + termDays * 1 days;
    require(maturityTime >= nominalEnd, "maturity before term end");
    require(maturityTime <= nominalEnd + MAX_ALIGN_WINDOW, "maturity too late");

    cohorts[cohortId] = Cohort({
      termDays: termDays,
      depositDeadline: depositDeadline,
      maturityTime: maturityTime,
      enabled: enabled
    });
    emit SetCohort(cohortId, termDays, depositDeadline, maturityTime, enabled);
  }

  /**
   * @dev set the early-redeem penalty rate charged on redeemed principal (1e18 =
   *      100%), bounded by MAX_PENALTY_RATE. Applies to redemptions within
   *      PENALTY_WINDOW of deposit.
   * @param _penaltyRate the new penalty rate, 1e18
   */
  function setPenaltyRate(uint256 _penaltyRate) external onlyRole(MANAGER) {
    require(_penaltyRate <= MAX_PENALTY_RATE, "penalty rate too high");
    penaltyRate = _penaltyRate;
    emit SetPenaltyRate(_penaltyRate);
  }

  /* INTERNAL FUNCTIONS */
  /**
   * @dev early-redeem payout on `amount` principal. Within PENALTY_WINDOW of the
   *      position's deposit time a flat `penaltyRate` is charged on the redeemed
   *      principal; past the window the full principal is returned. Interest is
   *      always forfeited on early redemption (distributed off-pool).
   *      payout = amount - (amount * penaltyRate / PRECISION)  [within window]
   *      payout = amount                                        [after window]
   */
  function _earlyRedeemPayout(uint256 depositTime, uint256 amount) internal view returns (uint256) {
    if (block.timestamp < depositTime + PENALTY_WINDOW) {
      uint256 penalty = (amount * penaltyRate) / PRECISION;
      return amount - penalty;
    }
    return amount;
  }
}
