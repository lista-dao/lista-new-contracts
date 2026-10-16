// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CreditFundBase } from "./CreditFundBase.sol";
import { CreditFundSharePool } from "./CreditFundSharePool.sol";

/**
 * @title RenaissNavPool
 * @notice Perpetual NAV product on the Surfin template: shares are minted at the latest
 *         published NAV and redeemed in quarterly cycles at the NAV published after the
 *         cycle closes (forward pricing). No interest is paid; every return is in the NAV.
 *
 *  - NAV: MANAGER publishes it (weekly). Within any window of `NAV_WINDOW` the NAV may
 *    move by at most `maxNavDeltaBps` from its value at the start of the window, so a
 *    mistyped file cannot reprice the pool in one week. A stale NAV is an operations
 *    matter (depositPaused).
 *  - Subscription: continuous, `shares = amount * 1e18 / nav`, bounded by `cap` measured
 *    on the pool's value (`totalSupply * nav`).
 *  - Redemption cycle, driven by MANAGER: openCycle -> requests (cancellable, escrowed in
 *    the pool) -> closeCycle (no more requests or cancels) -> settleCycle at a NAV
 *    published after the close. Every request of a cycle is priced at that one NAV.
 *    Settlement burns the escrowed shares and books the payout as one batch of the
 *    shared queue, so the adapter funds it like any other withdrawal and claims open only
 *    once the whole cycle is funded.
 *  - Lista's cut (`feeRate`, frozen per cycle at settlement) is taken from each payout at
 *    claim time.
 *
 * Wire it into the adapter's LOCKED slot with flexPool = address(0) and floorRate 0.
 * The template's daily batch queue is used only as the funding rail: `claimWithdraw`,
 * `getUserWithdrawalRequests` and `dailyLimit` are inert on this pool; `minWithdraw`
 * applies to the asset value of a redemption request.
 */
contract RenaissNavPool is CreditFundSharePool {
  using SafeERC20 for IERC20;

  /* TYPES */
  enum CycleState {
    None,
    Open,
    Closed,
    Settled
  }

  struct Cycle {
    CycleState state;
    uint256 requestedShares; // shares escrowed for this cycle (net of cancels)
    uint256 claimedShares; // shares whose payout has been claimed
    uint256 closedAt;
    uint256 settlementNav;
    uint256 batchId; // batch of the shared queue carrying this cycle's payout
    uint256 payout; // requestedShares valued at settlementNav
    uint256 paid; // payouts released so far (gross of fee)
    uint256 feeRate; // Lista's cut, frozen at settlement
  }

  struct Request {
    address owner;
    uint256 cycleId;
    uint256 shares;
    bool cancelled;
    bool claimed;
  }

  /* CONSTANTS */
  uint256 public constant NAV_PRECISION = 1e18;
  uint256 internal constant BPS = 10_000;
  // the NAV delta bound is measured over this window
  uint256 internal constant NAV_WINDOW = 7 days;
  // guardrail on the per-publication NAV move MANAGER may configure (50%)
  uint256 internal constant MAX_NAV_DELTA_BPS = 5_000;
  // guardrail on Lista's cut of a payout (30%)
  uint256 internal constant MAX_FEE_RATE = 0.3 ether;

  /* VARIABLES */
  // price per share, 1e18
  uint256 public nav;
  uint256 public navUpdatedAt;
  // NAV at the start of the current delta window, and when that window started
  uint256 public navAnchor;
  uint256 public navAnchorAt;
  // largest move the NAV may make within one window, bps of navAnchor
  uint256 public maxNavDeltaBps;
  // Lista's cut of each payout, 1e18; paid to feeReceiver at claim
  uint256 public feeRate;
  address public feeReceiver;

  uint256 public currentCycleId;
  mapping(uint256 => Cycle) public cycles;
  mapping(uint256 => Request) public requests;
  uint256 public nextRequestId;
  // owner => request ids not yet cancelled or claimed
  mapping(address => uint256[]) private activeRequestIds;
  // shares held in escrow for open and closed cycles (== balanceOf(address(this)))
  uint256 public totalEscrowed;

  /* EVENTS */
  event Subscribed(address indexed user, address indexed receiver, uint256 amount, uint256 shares, uint256 nav);
  event NavPublished(uint256 previousNav, uint256 nav);
  event CycleOpened(uint256 indexed cycleId);
  event CycleClosed(uint256 indexed cycleId, uint256 requestedShares);
  event CycleSettled(uint256 indexed cycleId, uint256 nav, uint256 shares, uint256 payout, uint256 batchId);
  event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 indexed cycleId, uint256 shares);
  event RedeemCancelled(uint256 indexed requestId, address indexed owner, uint256 indexed cycleId, uint256 shares);
  event RedeemClaimed(uint256 indexed requestId, address indexed owner, uint256 amount, uint256 fee);
  event SetMaxNavDeltaBps(uint256 maxNavDeltaBps);
  event SetFeeRate(uint256 feeRate);
  event SetFeeReceiver(address feeReceiver);

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  /**
   * @param _initialNav opening price per share (1e18); the first subscriptions mint at it
   */
  function initialize(
    address _admin,
    address _manager,
    address _pauser,
    address _bot,
    address _asset,
    address _adapter,
    string memory _name,
    string memory _symbol,
    uint256 _initialNav
  ) external initializer {
    require(_initialNav > 0, "nav is zero");
    __CreditFundSharePool_init(_admin, _manager, _pauser, _bot, _asset, _adapter, _name, _symbol);
    nav = _initialNav;
    navUpdatedAt = block.timestamp;
    navAnchor = _initialNav;
    navAnchorAt = block.timestamp;
    maxNavDeltaBps = 2_000;
    emit NavPublished(0, _initialNav);
    emit SetMaxNavDeltaBps(maxNavDeltaBps);
  }

  /* USER FUNCTIONS */
  /**
   * @dev subscribe at the latest published NAV; funds go straight to the adapter.
   * @param amount the amount of asset to deposit
   * @param receiver the receiver of the shares
   */
  function deposit(uint256 amount, address receiver) external whenNotPaused whenDepositNotPaused nonReentrant {
    _checkDeposit(receiver, amount);
    uint256 shares = (amount * NAV_PRECISION) / nav;
    require(shares > 0, "shares is zero");

    _mint(receiver, shares);
    IERC20(asset).safeTransferFrom(msg.sender, adapter, amount);

    emit Deposit(receiver, amount);
    emit Subscribed(msg.sender, receiver, amount, shares, nav);
  }

  /**
   * @dev request redemption of `shares` in the open cycle. The shares move into the
   *      pool's escrow until the request is cancelled or the cycle settles. Not gated by
   *      depositPaused: the restricted state only closes subscriptions.
   * @param shares the shares to redeem
   * @return requestId the id to cancel or claim with
   */
  function requestRedeem(uint256 shares) external whenNotPaused nonReentrant returns (uint256 requestId) {
    Cycle storage c = cycles[currentCycleId];
    require(c.state == CycleState.Open, "window closed");
    require(shares > 0, "shares is zero");
    uint256 value = (shares * nav) / NAV_PRECISION;
    require(value > 0, "request below 1 wei");
    _checkMinWithdraw(msg.sender, value, shares, balanceOf(msg.sender));

    c.requestedShares += shares;
    totalEscrowed += shares;
    _escrow(msg.sender, shares);

    requestId = nextRequestId++;
    requests[requestId] = Request({
      owner: msg.sender,
      cycleId: currentCycleId,
      shares: shares,
      cancelled: false,
      claimed: false
    });
    activeRequestIds[msg.sender].push(requestId);

    emit RedeemRequested(requestId, msg.sender, currentCycleId, shares);
  }

  /**
   * @dev cancel a request while its cycle is still open; the shares return to the owner
   *      and the quota to the cycle.
   * @param requestId the request to cancel
   */
  function cancelRedeem(uint256 requestId) external whenNotPaused nonReentrant {
    Request storage r = requests[requestId];
    require(r.owner == msg.sender, "not request owner");
    require(!r.cancelled && !r.claimed, "request closed");
    Cycle storage c = cycles[r.cycleId];
    require(c.state == CycleState.Open, "window closed");

    r.cancelled = true;
    c.requestedShares -= r.shares;
    totalEscrowed -= r.shares;
    _removeActive(msg.sender, requestId);
    _transfer(address(this), msg.sender, r.shares);

    emit RedeemCancelled(requestId, msg.sender, r.cycleId, r.shares);
  }

  /**
   * @dev claim the payouts of settled, funded requests. The owner claims, or the BOT on
   *      the owner's behalf; the cash always goes to the owner and Lista's cut to the
   *      fee receiver.
   * @param user the request owner
   * @param requestIds the requests to claim
   */
  function claimRedeem(address user, uint256[] calldata requestIds) external whenNotPaused nonReentrant {
    require(msg.sender == user || hasRole(BOT, msg.sender), "not authorized");
    uint256 total;
    uint256 totalFee;
    for (uint256 i = 0; i < requestIds.length; i++) {
      uint256 id = requestIds[i];
      Request storage r = requests[id];
      require(r.owner == user, "not request owner");
      require(!r.cancelled && !r.claimed, "request closed");
      Cycle storage c = cycles[r.cycleId];
      require(c.state == CycleState.Settled, "cycle not settled");
      require(c.batchId <= confirmedBatchId, "not able to claim yet");

      r.claimed = true;
      _removeActive(user, id);
      uint256 amount = (r.shares * c.settlementNav) / NAV_PRECISION;
      uint256 fee = (amount * c.feeRate) / PRECISION;
      c.claimedShares += r.shares;
      c.paid += amount;
      uint256 released = amount;
      if (c.claimedShares == c.requestedShares) {
        // last claim of the cycle: release the rounding remainder with it
        released += c.payout - c.paid;
        c.paid = c.payout;
      }
      totalPendingWithdraw -= released;
      totalConfirmedUnclaimed -= released;
      total += amount - fee;
      totalFee += fee;

      emit RedeemClaimed(id, user, amount - fee, fee);
    }
    if (total > 0) IERC20(asset).safeTransfer(user, total);
    if (totalFee > 0) IERC20(asset).safeTransfer(feeReceiver, totalFee);
  }

  /* MANAGER FUNCTIONS */
  /**
   * @dev publish the NAV. Bounded to `maxNavDeltaBps` away from the NAV at the start of
   *      the current `NAV_WINDOW`, in either direction, so repeated publications cannot
   *      compound past the bound within a week while a correction inside it stays possible.
   * @param newNav price per share, 1e18
   */
  function publishNav(uint256 newNav) external onlyRole(MANAGER) {
    require(newNav > 0, "nav is zero");
    if (block.timestamp >= navAnchorAt + NAV_WINDOW) {
      navAnchor = nav;
      navAnchorAt = block.timestamp;
    }
    uint256 limit = (navAnchor * maxNavDeltaBps) / BPS;
    require(newNav <= navAnchor + limit && newNav + limit >= navAnchor, "nav delta too large");
    emit NavPublished(nav, newNav);
    nav = newNav;
    navUpdatedAt = block.timestamp;
  }

  /// @dev open the request window of a new cycle; the previous one must be settled
  function openCycle() external onlyRole(MANAGER) {
    CycleState prev = cycles[currentCycleId].state;
    require(prev == CycleState.None || prev == CycleState.Settled, "cycle in progress");
    currentCycleId++;
    cycles[currentCycleId].state = CycleState.Open;
    emit CycleOpened(currentCycleId);
  }

  /// @dev close the window: no more requests or cancels; the list is final. Pause-gated so
  ///      a pause cannot swallow the cancel window.
  function closeCycle() external onlyRole(MANAGER) whenNotPaused {
    Cycle storage c = cycles[currentCycleId];
    require(c.state == CycleState.Open, "cycle not open");
    c.state = CycleState.Closed;
    c.closedAt = block.timestamp;
    emit CycleClosed(currentCycleId, c.requestedShares);
  }

  /**
   * @dev settle the closed cycle at the NAV published after it closed: burn the escrowed
   *      shares and book the payout as one batch of the queue for the adapter to fund.
   */
  function settleCycle() external onlyRole(MANAGER) {
    Cycle storage c = cycles[currentCycleId];
    require(c.state == CycleState.Closed, "cycle not closed");
    require(navUpdatedAt > c.closedAt, "nav not published since close");

    uint256 shares = c.requestedShares;
    uint256 payout = (shares * nav) / NAV_PRECISION;
    c.state = CycleState.Settled;
    c.settlementNav = nav;
    c.payout = payout;
    c.feeRate = feeRate;

    if (shares > 0) {
      totalEscrowed -= shares;
      _burn(address(this), shares);
    }
    if (payout > 0) {
      c.batchId = ++currentBatchId;
      totalWithdrawAmountInBatch[c.batchId] = payout;
      totalPendingWithdraw += payout;
    }

    emit CycleSettled(currentCycleId, nav, shares, payout, c.batchId);
  }

  function setMaxNavDeltaBps(uint256 _maxNavDeltaBps) external onlyRole(MANAGER) {
    require(_maxNavDeltaBps > 0 && _maxNavDeltaBps <= MAX_NAV_DELTA_BPS, "invalid nav delta");
    require(_maxNavDeltaBps != maxNavDeltaBps, "same nav delta");
    maxNavDeltaBps = _maxNavDeltaBps;
    emit SetMaxNavDeltaBps(_maxNavDeltaBps);
  }

  function setFeeRate(uint256 _feeRate) external onlyRole(MANAGER) {
    require(_feeRate <= MAX_FEE_RATE, "fee rate too high");
    require(_feeRate != feeRate, "same fee rate");
    require(_feeRate == 0 || feeReceiver != address(0), "feeReceiver is zero");
    feeRate = _feeRate;
    emit SetFeeRate(_feeRate);
  }

  function setFeeReceiver(address _feeReceiver) external onlyRole(MANAGER) {
    require(_feeReceiver != address(0), "feeReceiver is zero");
    require(_feeReceiver != feeReceiver, "same feeReceiver");
    feeReceiver = _feeReceiver;
    emit SetFeeReceiver(_feeReceiver);
  }

  /* VIEWS */
  /// @inheritdoc CreditFundBase
  /// @dev the outstanding shares valued at the published NAV
  function totalPrincipal() public view override returns (uint256) {
    return poolNav();
  }

  /// @dev value of all outstanding shares, escrow included, in asset units
  function poolNav() public view returns (uint256) {
    return (totalSupply() * nav) / NAV_PRECISION;
  }

  /// @dev settled payouts the partner has not funded yet: the pool's liability that the
  ///      published NAV must exclude from the partner's assets
  function unfundedPayout() external view returns (uint256) {
    return _unconfirmedObligation() - withdrawQuota;
  }

  function getActiveRequestIds(address user) external view returns (uint256[] memory) {
    return activeRequestIds[user];
  }

  /// @dev what a settled, funded request pays out, net of fee; 0 while it cannot be claimed
  function claimable(uint256 requestId) external view returns (uint256) {
    Request storage r = requests[requestId];
    Cycle storage c = cycles[r.cycleId];
    if (r.cancelled || r.claimed || c.state != CycleState.Settled || c.batchId > confirmedBatchId) return 0;
    uint256 amount = (r.shares * c.settlementNav) / NAV_PRECISION;
    return amount - (amount * c.feeRate) / PRECISION;
  }

  /* INTERNAL FUNCTIONS */
  /// @dev the pool's value is what the cap bounds
  function _capUsage() internal view override returns (uint256) {
    return poolNav();
  }

  function _removeActive(address user, uint256 requestId) internal {
    uint256[] storage ids = activeRequestIds[user];
    uint256 len = ids.length;
    for (uint256 i = 0; i < len; i++) {
      if (ids[i] == requestId) {
        ids[i] = ids[len - 1];
        ids.pop();
        return;
      }
    }
  }

  uint256[40] private __gap;
}
