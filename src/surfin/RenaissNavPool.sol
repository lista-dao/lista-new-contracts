// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CreditFundBase } from "./CreditFundBase.sol";
import { CreditFundSharePool } from "./CreditFundSharePool.sol";

/**
 * @title RenaissNavPool
 * @notice Perpetual NAV product on the Surfin template: shares are minted at the latest
 *         published NAV and redeemed in epochs at the NAV published after the epoch
 *         closes (forward pricing). No interest is paid; every return is in the NAV.
 *
 *  - NAV: MANAGER publishes it (weekly) after off-chain validation; the contract applies
 *    it as is. A stale NAV is an operations matter (depositPaused).
 *  - Subscription: continuous, `shares = amount * 1e18 / nav`, bounded by `cap` measured
 *    on the pool's value (`totalSupply * nav`).
 *  - Redemption epoch, driven by MANAGER: openEpoch -> requests (cancellable, escrowed in
 *    the pool) -> closeEpoch (no more requests or cancels) -> settleEpoch once the partner
 *    has paid: MANAGER brings in `requestedShares * nav`, the escrowed shares are burned,
 *    and every request of the epoch is then claimed in one go through `claimRedeem`
 *    (permissionless, batched by ids so a large epoch can be paid over several calls).
 *    Every request of an epoch is priced at that one settlement NAV.
 *  - Lista's cut (`feeRate`, frozen per epoch at settlement) is taken from each payout.
 *
 * Wire it into the adapter's LOCKED slot with flexPool = address(0) and floorRate 0; the
 * adapter only forwards subscriptions. Payouts never go through the template's batch
 * queue, so `claimWithdraw` and `getUserWithdrawalRequests` are inert on this pool.
 * `dailyLimit` is not applied to requests; leave it at 0, since it still bounds
 * `setMinWithdraw`. `minWithdraw` applies to the asset value of a redemption request.
 */
contract RenaissNavPool is CreditFundSharePool {
  using SafeERC20 for IERC20;

  /* TYPES */
  enum EpochState {
    None,
    Open,
    Closed,
    Settled
  }

  struct Epoch {
    EpochState state;
    uint256 requestedShares; // shares escrowed for this epoch (net of cancels)
    uint256 claimedShares; // shares whose payout has been claimed
    uint256 closedAt;
    uint256 settlementNav;
    uint256 payout; // requestedShares valued at settlementNav, brought in at settlement
    uint256 claimed; // payouts claimed so far (gross of fee)
    uint256 feeRate; // Lista's cut, frozen at settlement
  }

  struct Request {
    address owner;
    uint256 epochId;
    uint256 shares;
    bool cancelled;
    bool claimed;
  }

  /* CONSTANTS */
  uint256 public constant NAV_PRECISION = 1e18;
  // guardrail on Lista's cut of a payout (30%)
  uint256 internal constant MAX_FEE_RATE = 0.3 ether;

  /* VARIABLES */
  // price per share, 1e18
  uint256 public nav;
  uint256 public navUpdatedAt;
  // Lista's cut of each payout, 1e18; paid to feeReceiver
  uint256 public feeRate;
  address public feeReceiver;

  uint256 public currentEpochId;
  mapping(uint256 => Epoch) public epochs;
  mapping(uint256 => Request) public requests;
  uint256 public nextRequestId;
  // epoch id => every request submitted to it (cancelled ones included)
  mapping(uint256 => uint256[]) private epochRequestIds;
  // shares held in escrow for open and closed epochs (== balanceOf(address(this)))
  uint256 public totalEscrowed;
  // settled payouts not yet sent, gross of fee (<= asset balance of the pool)
  uint256 public totalOwed;

  /* EVENTS */
  event Subscribed(address indexed user, address indexed receiver, uint256 amount, uint256 shares, uint256 nav);
  event NavPublished(uint256 previousNav, uint256 nav);
  event EpochOpened(uint256 indexed epochId);
  event EpochClosed(uint256 indexed epochId, uint256 requestedShares);
  event EpochSettled(uint256 indexed epochId, uint256 nav, uint256 shares, uint256 payout);
  event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 indexed epochId, uint256 shares);
  event RedeemCancelled(uint256 indexed requestId, address indexed owner, uint256 indexed epochId, uint256 shares);
  event RedeemClaimed(uint256 indexed requestId, address indexed owner, uint256 amount, uint256 fee);
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
    emit NavPublished(0, _initialNav);
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
   * @dev request redemption of `shares` in the open epoch. The shares move into the
   *      pool's escrow until the request is cancelled or the epoch settles. Not gated by
   *      depositPaused: the restricted state only closes subscriptions.
   * @param shares the shares to redeem, or `type(uint256).max` for the whole balance
   * @return requestId the id to cancel with
   */
  function requestRedeem(uint256 shares) external whenNotPaused nonReentrant returns (uint256 requestId) {
    Epoch storage c = epochs[currentEpochId];
    require(c.state == EpochState.Open, "window closed");
    shares = _resolveAll(shares);
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
      epochId: currentEpochId,
      shares: shares,
      cancelled: false,
      claimed: false
    });
    epochRequestIds[currentEpochId].push(requestId);

    emit RedeemRequested(requestId, msg.sender, currentEpochId, shares);
  }

  /**
   * @dev cancel a request while its epoch is still open; the shares return to the owner.
   * @param requestId the request to cancel
   */
  function cancelRedeem(uint256 requestId) external whenNotPaused nonReentrant {
    Request storage r = requests[requestId];
    require(r.owner == msg.sender, "not request owner");
    require(!r.cancelled, "request cancelled");
    Epoch storage c = epochs[r.epochId];
    require(c.state == EpochState.Open, "window closed");

    r.cancelled = true;
    c.requestedShares -= r.shares;
    totalEscrowed -= r.shares;
    _transfer(address(this), msg.sender, r.shares);

    emit RedeemCancelled(requestId, msg.sender, r.epochId, r.shares);
  }

  /**
   * @dev claim the settled requests in `requestIds`: each owner receives
   *      `shares * settlementNav` less Lista's cut. Permissionless, since the cash can only
   *      go to the request owners and the fee receiver. Cancelled or already claimed ids are
   *      skipped, so an epoch's full id list can be passed as is, in batches if it is large.
   *      With the last payout of an epoch, the rounding remainder of the epoch's payout goes
   *      to the fee receiver (or stays in the pool if none is set).
   * @param requestIds settled requests to claim
   */
  function claimRedeem(uint256[] calldata requestIds) external whenNotPaused nonReentrant {
    uint256 fees;
    for (uint256 i = 0; i < requestIds.length; i++) {
      Request storage r = requests[requestIds[i]];
      require(r.owner != address(0), "unknown request");
      Epoch storage c = epochs[r.epochId];
      require(c.state == EpochState.Settled, "epoch not settled");
      if (r.cancelled || r.claimed) continue;

      r.claimed = true;
      uint256 amount = (r.shares * c.settlementNav) / NAV_PRECISION;
      uint256 fee = (amount * c.feeRate) / PRECISION;
      uint256 net = amount - fee;
      c.claimedShares += r.shares;
      c.claimed += amount;
      uint256 released = amount;
      if (c.claimedShares == c.requestedShares) {
        uint256 remainder = c.payout - c.claimed;
        c.claimed = c.payout;
        released += remainder;
        if (feeReceiver != address(0)) fee += remainder;
      }
      totalOwed -= released;
      fees += fee;
      if (net > 0) IERC20(asset).safeTransfer(r.owner, net);

      emit RedeemClaimed(requestIds[i], r.owner, net, fee);
    }
    if (fees > 0) IERC20(asset).safeTransfer(feeReceiver, fees);
  }

  /* MANAGER FUNCTIONS */
  /**
   * @dev publish the NAV. The value is validated off-chain before the multisig submits it;
   *      the contract only rejects zero.
   * @param newNav price per share, 1e18
   */
  function publishNav(uint256 newNav) external onlyRole(MANAGER) {
    require(newNav > 0, "nav is zero");
    emit NavPublished(nav, newNav);
    nav = newNav;
    navUpdatedAt = block.timestamp;
  }

  /// @dev open the request window of a new epoch; the previous one must be settled
  function openEpoch() external onlyRole(MANAGER) {
    EpochState prev = epochs[currentEpochId].state;
    require(prev == EpochState.None || prev == EpochState.Settled, "epoch in progress");
    currentEpochId++;
    epochs[currentEpochId].state = EpochState.Open;
    emit EpochOpened(currentEpochId);
  }

  /// @dev close the window: no more requests or cancels; the list is final. Pause-gated so
  ///      a pause cannot swallow the cancel window.
  function closeEpoch() external onlyRole(MANAGER) whenNotPaused {
    Epoch storage c = epochs[currentEpochId];
    require(c.state == EpochState.Open, "epoch not open");
    c.state = EpochState.Closed;
    c.closedAt = block.timestamp;
    emit EpochClosed(currentEpochId, c.requestedShares);
  }

  /**
   * @dev settle the closed epoch at the NAV published after it closed: the caller brings
   *      in the whole payout (`requestedShares * nav`, approve first), the escrowed shares
   *      are burned, and the requests become claimable through `claimRedeem`.
   */
  function settleEpoch() external onlyRole(MANAGER) nonReentrant {
    Epoch storage c = epochs[currentEpochId];
    require(c.state == EpochState.Closed, "epoch not closed");
    require(navUpdatedAt > c.closedAt, "nav not published since close");

    uint256 shares = c.requestedShares;
    uint256 payout = (shares * nav) / NAV_PRECISION;
    c.state = EpochState.Settled;
    c.settlementNav = nav;
    c.payout = payout;
    c.feeRate = feeRate;

    if (shares > 0) {
      totalEscrowed -= shares;
      _burn(address(this), shares);
    }
    if (payout > 0) {
      totalOwed += payout;
      IERC20(asset).safeTransferFrom(msg.sender, address(this), payout);
    }

    emit EpochSettled(currentEpochId, nav, shares, payout);
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

  /// @dev every request submitted to an epoch, in submission order (cancelled ones included)
  function getEpochRequestIds(uint256 epochId) external view returns (uint256[] memory) {
    return epochRequestIds[epochId];
  }

  /* INTERNAL FUNCTIONS */
  /// @dev the pool's value is what the cap bounds
  function _capUsage() internal view override returns (uint256) {
    return poolNav();
  }

  uint256[39] private __gap;
}
