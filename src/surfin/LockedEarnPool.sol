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
 * shares the same schedule and one update covers them all. A position snapshots
 * its base rate (`baseQuote`) at deposit for rate certainty. Early redemption
 * (partial allowed) forfeits accrued interest and, if that is not enough, takes a
 * minimum penalty equal to 30 days of base interest from the redeemed principal.
 * Interest (base + loyalty) is distributed off-pool via the cumulative Merkle
 * InterestDistributor; renewal rolls the principal only into a fresh cohort.
 */
contract LockedEarnPool is CreditFundBase {
  using SafeERC20 for IERC20;

  /* STRUCTS */
  // a single locked position (dates live on the referenced cohort)
  struct Position {
    uint256 principal; // principal amount
    uint256 cohortId; // issuance batch this position belongs to
    uint256 baseQuote; // base APR snapshot at deposit, 1e18 (e.g. 0.114e18)
    bool autoRenew; // roll principal into a new term on maturity
    bool closed; // position terminated (redeemed / matured-out / renewed)
  }

  // an issuance batch (cohort). Dates are settlement-aligned and injected
  // off-chain by the manager; all positions in a cohort share them, so one
  // update covers the whole batch ("same batch, same maturity").
  struct Cohort {
    uint256 termDays; // nominal lock term in days (bounds the maturity)
    uint256 baseQuote; // base APR, 1e18
    uint256 depositDeadline; // deposits accepted until this time
    uint256 interestStartTime; // interest-accrual start (penalty anchor)
    uint256 maturityTime; // maturity date (settlement-aligned)
    bool enabled; // open for deposit
  }

  /* CONSTANTS */
  // days of base interest used as the minimum early-redeem penalty
  uint256 public constant MIN_PENALTY_DAYS = 30;
  // day count basis (actual/365, matching the Surfin facility)
  uint256 public constant DAY_COUNT = 365;
  // guardrail: interest start can be at most this far after deposits close
  uint256 public constant MAX_START_DELAY = 7 days;
  // guardrail: maturity can be at most this far past the nominal term end
  uint256 public constant MAX_ALIGN_WINDOW = 31 days;
  // auto-renew is locked within this window before maturity (T-30 checkpoint)
  uint256 public constant AUTO_RENEW_LOCK_WINDOW = 30 days;

  /* VARIABLES */
  // user => positions
  mapping(address => Position[]) internal userPositions;
  // total principal across all open positions
  uint256 public totalPrincipalAmount;
  // cohort id => issuance batch config
  mapping(uint256 => Cohort) public cohorts;

  /* EVENTS */
  event LockedDeposit(address indexed user, uint256 posId, uint256 cohortId, uint256 amount, uint256 maturityTime);
  event RequestEarlyRedeem(address indexed user, uint256 posId, uint256 amount, uint256 payout, uint256 batchId);
  event RequestMaturityWithdraw(address indexed user, uint256 posId, uint256 principal, uint256 batchId);
  event RenewPosition(address indexed user, uint256 oldPosId, uint256 newPosId, uint256 principal);
  event ToggleAutoRenew(address indexed user, uint256 posId, bool autoRenew);
  event SetCohort(
    uint256 cohortId,
    uint256 termDays,
    uint256 baseQuote,
    uint256 depositDeadline,
    uint256 interestStartTime,
    uint256 maturityTime,
    bool enabled
  );

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
  }

  /* EXTERNAL FUNCTIONS */
  /**
   * @dev deposit into a cohort; funds go straight to the adapter.
   * @param cohortId the issuance batch id
   * @param amount the amount of asset to deposit
   * @param receiver the owner of the new position
   */
  function deposit(
    uint256 cohortId,
    uint256 amount,
    address receiver
  ) external whenNotPaused whenDepositNotPaused nonReentrant {
    Cohort memory c = cohorts[cohortId];
    require(c.enabled, "cohort not enabled");
    require(block.timestamp <= c.depositDeadline, "deposit window closed");
    require(amount > 0, "amount is zero");
    require(receiver != address(0), "receiver is zero address");
    require(isInWhitelist(receiver), "receiver not in whitelist");
    require(amount >= minDeposit, "deposit below minimum");

    userPositions[receiver].push(
      Position({ principal: amount, cohortId: cohortId, baseQuote: c.baseQuote, autoRenew: false, closed: false })
    );
    totalPrincipalAmount += amount;

    IERC20(asset).safeTransferFrom(msg.sender, adapter, amount);

    emit LockedDeposit(receiver, userPositions[receiver].length - 1, cohortId, amount, c.maturityTime);
  }

  /**
   * @dev request early redemption of `amount` principal from a position (partial
   *      allowed). Accrued interest is forfeited; a shortfall to the 30-day
   *      minimum penalty is taken from the redeemed principal. The payout enters
   *      the batch queue. The position stays open with reduced principal, or is
   *      closed once fully redeemed.
   * @param posId the caller's position id
   * @param amount the principal amount to early-redeem
   */
  function requestEarlyRedeem(uint256 posId, uint256 amount) external whenNotPaused whenDepositNotPaused nonReentrant {
    Position storage pos = userPositions[msg.sender][posId];
    require(pos.principal > 0 && !pos.closed, "invalid position");
    require(amount > 0 && amount <= pos.principal, "invalid amount");

    Cohort memory c = cohorts[pos.cohortId];
    require(block.timestamp < c.maturityTime, "already matured");

    uint256 payout = _earlyRedeemPayout(pos.baseQuote, c.interestStartTime, amount);

    pos.principal -= amount;
    if (pos.principal == 0) {
      pos.closed = true;
    }
    totalPrincipalAmount -= amount;

    _consumeDailyLimit(msg.sender, payout);
    uint256 batchId = _enqueueWithdraw(msg.sender, payout);

    emit RequestEarlyRedeem(msg.sender, posId, amount, payout, batchId);
  }

  /**
   * @dev request withdraw of a matured position (only when not auto-renewing).
   *      Principal enters the batch queue, covered by the adapter's settlement
   *      reserve. No daily limit is applied to matured principal.
   * @param posId the caller's position id
   */
  function requestMaturityWithdraw(uint256 posId) external whenNotPaused nonReentrant {
    Position storage pos = userPositions[msg.sender][posId];
    require(pos.principal > 0 && !pos.closed, "invalid position");
    require(block.timestamp >= cohorts[pos.cohortId].maturityTime, "not matured");
    require(!pos.autoRenew, "auto renew on");

    uint256 principal = pos.principal;
    pos.closed = true;
    totalPrincipalAmount -= principal;

    uint256 batchId = _enqueueWithdraw(msg.sender, principal);

    emit RequestMaturityWithdraw(msg.sender, posId, principal, batchId);
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
      Position({ principal: principal, cohortId: newCohortId, baseQuote: c.baseQuote, autoRenew: false, closed: false })
    );
    // totalPrincipalAmount unchanged: principal moves from old to new position

    emit RenewPosition(user, posId, userPositions[user].length - 1, principal);
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
    return _earlyRedeemPayout(pos.baseQuote, cohorts[pos.cohortId].interestStartTime, amount);
  }

  /* MANAGER FUNCTIONS */
  /**
   * @dev create or adjust a cohort (issuance batch). Dates are injected off-chain
   *      but bounded on-chain: the interest start must fall within MAX_START_DELAY
   *      of the deposit deadline, and the maturity must land between the nominal
   *      term end and MAX_ALIGN_WINDOW past it. These guardrails keep the manager
   *      from arbitrarily extending or shortening outstanding positions.
   * @param cohortId the cohort id
   * @param termDays nominal lock term in days
   * @param baseQuote base APR, 1e18
   * @param depositDeadline last time deposits are accepted into this cohort
   * @param interestStartTime interest-accrual start (settlement-aligned)
   * @param maturityTime maturity date (settlement-aligned)
   * @param enabled whether the cohort is open for deposit
   */
  function setCohort(
    uint256 cohortId,
    uint256 termDays,
    uint256 baseQuote,
    uint256 depositDeadline,
    uint256 interestStartTime,
    uint256 maturityTime,
    bool enabled
  ) external onlyRole(MANAGER) {
    require(termDays > 0, "term is zero");
    require(baseQuote > 0, "baseQuote is zero");
    require(depositDeadline <= interestStartTime, "start before deposits close");
    require(interestStartTime <= depositDeadline + MAX_START_DELAY, "start too late");
    uint256 nominalEnd = interestStartTime + termDays * 1 days;
    require(maturityTime >= nominalEnd, "maturity before term end");
    require(maturityTime <= nominalEnd + MAX_ALIGN_WINDOW, "maturity too late");

    cohorts[cohortId] = Cohort({
      termDays: termDays,
      baseQuote: baseQuote,
      depositDeadline: depositDeadline,
      interestStartTime: interestStartTime,
      maturityTime: maturityTime,
      enabled: enabled
    });
    emit SetCohort(cohortId, termDays, baseQuote, depositDeadline, interestStartTime, maturityTime, enabled);
  }

  /* INTERNAL FUNCTIONS */
  /**
   * @dev payout = amount - max(0, minPenalty - accruedBase)
   *      minPenalty  = amount * baseQuote * 30 / 365
   *      accruedBase = amount * baseQuote * elapsedDays / 365
   *      elapsedDays counts from the cohort's interest-accrual start (0 before it starts).
   */
  function _earlyRedeemPayout(
    uint256 baseQuote,
    uint256 interestStartTime,
    uint256 amount
  ) internal view returns (uint256) {
    uint256 minPenalty = (amount * baseQuote * MIN_PENALTY_DAYS) / DAY_COUNT / PRECISION;

    uint256 elapsedDays = block.timestamp <= interestStartTime ? 0 : (block.timestamp - interestStartTime) / 1 days;
    uint256 accruedBase = (amount * baseQuote * elapsedDays) / DAY_COUNT / PRECISION;

    if (accruedBase >= minPenalty) {
      return amount;
    }
    return amount - (minPenalty - accruedBase);
  }
}
