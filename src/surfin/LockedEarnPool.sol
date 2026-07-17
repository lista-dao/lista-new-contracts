// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CreditFundBase } from "./CreditFundBase.sol";

/**
 * @title LockedEarnPool
 * @notice Locked (term) product of the Surfin Credit Fund (e.g. 3M+, 6M+).
 *
 * Each deposit creates an independent position with its own maturity and a base
 * rate snapshot (`baseQuote`) taken at deposit time. Early redemption forfeits
 * accrued interest and, if that is not enough, a minimum penalty equal to 30 days
 * of base interest is taken from principal. Interest (base + loyalty) is
 * distributed off-pool via the cumulative Merkle InterestDistributor; renewal
 * rolls the principal only into a fresh position (interest is distributed separately).
 */
contract LockedEarnPool is CreditFundBase {
  using SafeERC20 for IERC20;

  /* STRUCTS */
  // a single locked position
  struct Position {
    uint256 principal; // principal amount
    uint256 startTime; // interest-accrual start (used for penalty math)
    uint256 maturityTime; // maturity timestamp
    uint256 baseQuote; // base APR snapshot at deposit, 1e18 (e.g. 0.114e18)
    bool autoRenew; // roll principal into a new term on maturity
    bool closed; // position terminated (redeemed / matured-out / renewed)
  }

  // a configurable locked product
  struct LockedProduct {
    uint256 durationDays; // lock duration in days
    uint256 baseQuote; // base APR, 1e18
    bool enabled; // open for deposit
  }

  /* CONSTANTS */
  // days of base interest used as the minimum early-redeem penalty
  uint256 public constant MIN_PENALTY_DAYS = 30;
  // day count basis (actual/365, matching the Surfin facility)
  uint256 public constant DAY_COUNT = 365;

  /* VARIABLES */
  // user => positions
  mapping(address => Position[]) internal userPositions;
  // total principal across all open positions
  uint256 public totalPrincipalAmount;
  // product id => product config
  mapping(uint256 => LockedProduct) public products;

  /* EVENTS */
  event LockedDeposit(address indexed user, uint256 posId, uint256 productId, uint256 amount, uint256 maturityTime);
  event RequestEarlyRedeem(address indexed user, uint256 posId, uint256 payout, uint256 batchId);
  event RequestMaturityWithdraw(address indexed user, uint256 posId, uint256 principal, uint256 batchId);
  event RenewPosition(address indexed user, uint256 oldPosId, uint256 newPosId, uint256 principal);
  event ToggleAutoRenew(address indexed user, uint256 posId, bool autoRenew);
  event SetProduct(uint256 productId, uint256 durationDays, uint256 baseQuote, bool enabled);

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
   * @dev deposit into a locked product; funds go straight to the adapter.
   * @param productId the locked product id
   * @param amount the amount of asset to deposit
   * @param receiver the owner of the new position
   */
  function deposit(uint256 productId, uint256 amount, address receiver) external whenNotPaused nonReentrant {
    LockedProduct memory p = products[productId];
    require(p.enabled, "product not enabled");
    require(amount > 0, "amount is zero");
    require(receiver != address(0), "receiver is zero address");
    require(isInWhitelist(receiver), "receiver not in whitelist");
    require(amount >= minDeposit, "deposit below minimum");

    uint256 maturityTime = block.timestamp + p.durationDays * 1 days;
    userPositions[receiver].push(
      Position({
        principal: amount,
        startTime: block.timestamp,
        maturityTime: maturityTime,
        baseQuote: p.baseQuote,
        autoRenew: false,
        closed: false
      })
    );
    totalPrincipalAmount += amount;

    IERC20(asset).safeTransferFrom(msg.sender, adapter, amount);

    emit LockedDeposit(receiver, userPositions[receiver].length - 1, productId, amount, maturityTime);
  }

  /**
   * @dev request early redemption of a position (whole position only).
   *      Accrued interest is forfeited; a shortfall to the 30-day minimum
   *      penalty is taken from principal. The payout enters the batch queue.
   * @param posId the caller's position id
   */
  function requestEarlyRedeem(uint256 posId) external whenNotPaused nonReentrant {
    Position storage pos = userPositions[msg.sender][posId];
    require(pos.principal > 0 && !pos.closed, "invalid position");
    require(block.timestamp < pos.maturityTime, "already matured");

    uint256 payout = _earlyRedeemPayout(pos);

    pos.closed = true;
    totalPrincipalAmount -= pos.principal;

    _consumeDailyLimit(msg.sender, payout);
    uint256 batchId = _enqueueWithdraw(msg.sender, payout);

    emit RequestEarlyRedeem(msg.sender, posId, payout, batchId);
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
    require(block.timestamp >= pos.maturityTime, "not matured");
    require(!pos.autoRenew, "auto renew on");

    uint256 principal = pos.principal;
    pos.closed = true;
    totalPrincipalAmount -= principal;

    uint256 batchId = _enqueueWithdraw(msg.sender, principal);

    emit RequestMaturityWithdraw(msg.sender, posId, principal, batchId);
  }

  /**
   * @dev toggle auto-renew for a position (allowed before maturity; the backend
   *      locks changes from the T-30 checkpoint off-chain).
   * @param posId the caller's position id
   */
  function toggleAutoRenew(uint256 posId) external whenNotPaused {
    Position storage pos = userPositions[msg.sender][posId];
    require(pos.principal > 0 && !pos.closed, "invalid position");
    require(block.timestamp < pos.maturityTime, "already matured");

    pos.autoRenew = !pos.autoRenew;
    emit ToggleAutoRenew(msg.sender, posId, pos.autoRenew);
  }

  /**
   * @dev roll a matured auto-renew position's principal into a fresh term.
   *      Only principal is rolled (interest is claimed separately). Renewal is
   *      limited to one term: the new position has auto-renew forced off.
   *      Driven by the settlement-day job (BOT).
   * @param user the position owner
   * @param posId the matured position id
   * @param productId the product to renew into
   */
  function renewPosition(address user, uint256 posId, uint256 productId) external onlyRole(BOT) nonReentrant {
    Position storage pos = userPositions[user][posId];
    require(pos.principal > 0 && !pos.closed, "invalid position");
    require(pos.autoRenew, "auto renew off");
    require(block.timestamp >= pos.maturityTime, "not matured");

    LockedProduct memory p = products[productId];
    require(p.enabled, "product not enabled");

    uint256 principal = pos.principal;
    pos.closed = true;

    uint256 maturityTime = block.timestamp + p.durationDays * 1 days;
    userPositions[user].push(
      Position({
        principal: principal,
        startTime: block.timestamp,
        maturityTime: maturityTime,
        baseQuote: p.baseQuote,
        autoRenew: false,
        closed: false
      })
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
   * @dev preview the early-redeem payout for a position.
   */
  function previewEarlyRedeem(address user, uint256 posId) external view returns (uint256) {
    return _earlyRedeemPayout(userPositions[user][posId]);
  }

  /* MANAGER FUNCTIONS */
  /**
   * @dev configure a locked product.
   * @param productId the product id
   * @param durationDays lock duration in days
   * @param baseQuote base APR, 1e18
   * @param enabled whether the product is open for deposit
   */
  function setProduct(
    uint256 productId,
    uint256 durationDays,
    uint256 baseQuote,
    bool enabled
  ) external onlyRole(MANAGER) {
    require(durationDays > 0, "duration is zero");
    require(baseQuote > 0, "baseQuote is zero");
    products[productId] = LockedProduct({ durationDays: durationDays, baseQuote: baseQuote, enabled: enabled });
    emit SetProduct(productId, durationDays, baseQuote, enabled);
  }

  /* INTERNAL FUNCTIONS */
  /**
   * @dev payout = principal - max(0, minPenalty - accruedBase)
   *      minPenalty  = principal * baseQuote * 30 / 365
   *      accruedBase = principal * baseQuote * elapsedDays / 365
   */
  function _earlyRedeemPayout(Position memory pos) internal view returns (uint256) {
    uint256 minPenalty = (pos.principal * pos.baseQuote * MIN_PENALTY_DAYS) / DAY_COUNT / PRECISION;

    uint256 elapsedDays = (block.timestamp - pos.startTime) / 1 days;
    uint256 accruedBase = (pos.principal * pos.baseQuote * elapsedDays) / DAY_COUNT / PRECISION;

    if (accruedBase >= minPenalty) {
      return pos.principal;
    }
    return pos.principal - (minPenalty - accruedBase);
  }

  // reserve storage for future upgrades
  uint256[47] private __gap;
}
