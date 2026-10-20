// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CreditFundBase } from "./CreditFundBase.sol";
import { CreditFundSharePool } from "./CreditFundSharePool.sol";

/**
 * @title BpnEarnPool
 * @notice Demand product on the Surfin template with a 1:1 share and escrowed redemption
 *         requests that are settled share by share, so a request can be paid in parts.
 *
 *  - Shares: bookkeeping only, not transferable. They are minted on deposit, moved into
 *    the pool's escrow on request and burned out of it at settlement; `transfer` and
 *    `transferFrom` between holders revert.
 *  - Deposit: mints shares 1:1 and forwards the asset to the adapter.
 *  - Request: `requestRedeem` moves the shares into the pool's escrow; the request keeps
 *    them until they are settled. There is no cancel path.
 *  - Funding: the adapter pushes cash in through `finishWithdraw` (the template's rail),
 *    bounded by the escrowed shares not yet settled.
 *  - Settlement: BOT assigns funded cash to requests with `settleRedeem`, any number of
 *    shares per request up to what is still escrowed; the settled shares are burned and
 *    their value becomes claimable. Which requests are paid, when and how much is decided
 *    off-chain; the contract only bounds it by the escrow and the funded cash.
 *  - Claim: `claimRedeem` sends every claimable amount to the request owners; anyone may
 *    call it, the cash can only go to the owners.
 *
 * Interest is paid off-pool through the cumulative Merkle InterestDistributor.
 *
 * Wire it into the adapter's FLEX slot (lockedPool = address(0)) with floorRate 0. The
 * template's batch queue is unused: `claimWithdraw` and `getUserWithdrawalRequests` are
 * inert on this pool. `dailyLimit` is not applied to requests; leave it at 0, since it
 * still bounds `setMinWithdraw`. `minWithdraw` applies to a request's shares.
 *
 * Template accounting, in asset units (1 share = 1 unit):
 *   totalPendingWithdraw    = escrowed shares + settled, unclaimed amounts
 *   totalConfirmedUnclaimed = settled, unclaimed amounts
 *   withdrawQuota           = cash pushed in, not yet assigned to a request
 * so the adapter's unfunded queue is the escrow not yet covered by quota.
 */
contract BpnEarnPool is CreditFundSharePool {
  using SafeERC20 for IERC20;

  /* TYPES */
  struct Request {
    address owner;
    uint256 requestedAt;
    uint256 shares; // requested
    uint256 pending; // escrowed, not yet settled
    uint256 claimable; // settled, not yet claimed
  }

  /* VARIABLES */
  mapping(uint256 => Request) public requests;
  uint256 public nextRequestId;
  // owner => every request they submitted, in submission order
  mapping(address => uint256[]) private userRequestIds;
  // shares held in escrow for unsettled requests (== balanceOf(address(this)))
  uint256 public totalEscrowed;

  /* EVENTS */
  event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 shares);
  event RedeemSettled(uint256 indexed requestId, address indexed owner, uint256 shares, uint256 pending);
  event RedeemClaimed(uint256 indexed requestId, address indexed owner, uint256 amount);

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
    __CreditFundSharePool_init(_admin, _manager, _pauser, _bot, _asset, _adapter, _name, _symbol);
  }

  /* USER FUNCTIONS */
  /**
   * @dev deposit asset; mints shares 1:1 and forwards the funds to the adapter.
   * @param amount the amount of asset to deposit
   * @param receiver the receiver of the shares
   */
  function deposit(uint256 amount, address receiver) external whenNotPaused whenDepositNotPaused nonReentrant {
    _checkDeposit(receiver, amount);

    _mint(receiver, amount);
    IERC20(asset).safeTransferFrom(msg.sender, adapter, amount);

    emit Deposit(receiver, amount);
  }

  /**
   * @dev request redemption of `shares`; they move into the pool's escrow until settled.
   *      Not gated by depositPaused: the restricted state only closes deposits.
   * @param shares the shares to redeem, or `type(uint256).max` for the whole balance
   * @return requestId the id the request is settled and claimed by
   */
  function requestRedeem(uint256 shares) external whenNotPaused nonReentrant returns (uint256 requestId) {
    shares = _resolveAll(shares);
    require(shares > 0, "shares is zero");
    uint256 balance = balanceOf(msg.sender);
    require(balance >= shares, "insufficient balance");
    // min-withdraw floor with dust exit: a sub-min request must drain the balance
    _checkMinWithdraw(msg.sender, shares, shares, balance);

    totalEscrowed += shares;
    totalPendingWithdraw += shares;
    _escrow(msg.sender, shares);

    requestId = nextRequestId++;
    requests[requestId] = Request({
      owner: msg.sender,
      requestedAt: block.timestamp,
      shares: shares,
      pending: shares,
      claimable: 0
    });
    userRequestIds[msg.sender].push(requestId);

    emit RedeemRequested(requestId, msg.sender, shares);
  }

  /**
   * @dev send the claimable amount of each request in `requestIds` to its owner.
   *      Permissionless, since the cash can only go to the owners. Requests with nothing
   *      claimable are skipped, so an owner's full id list can be passed as is.
   * @param requestIds the requests to claim
   */
  function claimRedeem(uint256[] calldata requestIds) external whenNotPaused nonReentrant {
    for (uint256 i = 0; i < requestIds.length; i++) {
      Request storage r = requests[requestIds[i]];
      require(r.owner != address(0), "unknown request");
      uint256 amount = r.claimable;
      if (amount == 0) continue;

      r.claimable = 0;
      totalPendingWithdraw -= amount;
      totalConfirmedUnclaimed -= amount;
      IERC20(asset).safeTransfer(r.owner, amount);

      emit RedeemClaimed(requestIds[i], r.owner, amount);
    }
  }

  /* BOT FUNCTIONS */
  /**
   * @dev assign funded cash to requests: `shares[i]` of request `requestIds[i]` are
   *      settled, burned out of the escrow and become claimable 1:1. A request may be
   *      settled in several parts. The total must fit in the cash the adapter has pushed
   *      in (`withdrawQuota`). Pause-gated: a pause freezes the allocation of funded cash,
   *      which cannot be undone; cash pushed in meanwhile waits as quota.
   * @param requestIds the requests to settle
   * @param shares the shares to settle on each request
   */
  function settleRedeem(
    uint256[] calldata requestIds,
    uint256[] calldata shares
  ) external onlyRole(BOT) whenNotPaused nonReentrant {
    require(requestIds.length == shares.length, "length mismatch");
    uint256 total;
    for (uint256 i = 0; i < requestIds.length; i++) {
      Request storage r = requests[requestIds[i]];
      require(r.owner != address(0), "unknown request");
      uint256 s = shares[i];
      require(s > 0 && s <= r.pending, "invalid shares");

      r.pending -= s;
      r.claimable += s;
      total += s;

      emit RedeemSettled(requestIds[i], r.owner, s, r.pending);
    }
    require(total <= withdrawQuota, "exceeds quota");

    withdrawQuota -= total;
    totalConfirmedUnclaimed += total;
    totalEscrowed -= total;
    _burn(address(this), total);
  }

  /* VIEWS */
  /// @inheritdoc CreditFundBase
  /// @dev the shares still earning: outstanding supply less the escrow
  function totalPrincipal() public view override returns (uint256) {
    return totalSupply() - totalEscrowed;
  }

  /// @dev every request `user` submitted, in submission order
  function getUserRequestIds(address user) external view returns (uint256[] memory) {
    return userRequestIds[user];
  }

  /* INTERNAL FUNCTIONS */
  /// @dev the outstanding supply, escrow included: a request frees no capacity until it
  ///      is settled
  function _capUsage() internal view override returns (uint256) {
    return totalSupply();
  }

  /// @dev the only share moves are mint (deposit), into the pool (escrow; the base
  ///      rejects it outside `_escrow`) and burn (settlement)
  function _update(address from, address to, uint256 value) internal override {
    require(from == address(0) || to == address(0) || to == address(this), "non-transferable");
    super._update(from, to, value);
  }

  uint256[46] private __gap;
}
