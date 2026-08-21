// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICreditFundPool } from "./interface/ICreditFundPool.sol";
import { IInterestDistributor } from "./interface/IInterestDistributor.sol";

/**
 * @title SurfinAdapter
 * @notice Shared adapter for the Surfin Credit Fund, following the design of
 *         lista-new-contracts/src/rwa/RWAAdapter.sol.
 *
 * Both the flex and locked pools forward user deposits straight to this adapter,
 * so all fund logic lives here:
 *  - deploy idle funds to Surfin (off-chain) by transferring straight to Surfin's
 *    receiving wallet, not split by product — one combined transfer;
 *  - enforce a single on-chain hard floor (3% of both pools' live book) that is
 *    never paid out and doubles as the interest reserve; the 15% buffer target is
 *    maintained off-chain;
 *  - repay the pools' batch queues and book interest, bounded by that floor.
 */
contract SurfinAdapter is AccessControlEnumerableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
  using SafeERC20 for IERC20;

  /* VARIABLES */
  // flex (demand) pool
  address public flexPool;
  // locked (term) pool
  address public lockedPool;
  // Surfin receiving wallet (off-chain custody/multisig that funds are deployed to)
  address public surfinWallet;
  // interest distributor (cumulative Merkle interest payouts)
  address public interestDistributor;

  // accrued Lista profit fee earmark; the BOT claims it, only to the manager-set feeReceiver
  uint256 public accruedFee;
  // book value currently deployed to Surfin
  uint256 public deployedToSurfin;

  // single hard-floor rate over both pools' live book, 1e18 (e.g. 0.03e18 = 3%).
  // The 15% buffer target is maintained off-chain; only the hard floor is enforced
  // on-chain (also doubles as the interest reserve).
  uint256 public floorRate;

  // profit fee receiver (accruedFee is paid out here by claimFee)
  address public feeReceiver;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  uint256 public constant PRECISION = 1e18;

  /* IMMUTABLE */
  // asset token (USDT)
  address public immutable asset;

  /* EVENTS */
  event DeployToSurfin(uint256 amount);
  event FinishFlexWithdraw(uint256 amount);
  event FinishLockedWithdraw(uint256 amount);
  event FundInterest(uint256 amount);
  event ClaimFee(address receiver, uint256 amount);
  event SettleRecall(uint256 recalledAmount, uint256 lockedCoverAmount, uint256 feeAmount, uint256 deployedBookValue);
  event SetFloorRate(uint256 floorRate);
  event SetSurfinWallet(address surfinWallet);
  event SetInterestDistributor(address interestDistributor);
  event SetFeeReceiver(address feeReceiver);
  event EmergencyWithdraw(address indexed token, address indexed receiver, uint256 amount);

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param _asset The address of the asset token (USDT).
  constructor(address _asset) {
    require(_asset != address(0), "asset is zero address");
    _disableInitializers();
    asset = _asset;
  }

  /* INITIALIZER */
  function initialize(
    address _admin,
    address _manager,
    address _pauser,
    address _bot,
    address _flexPool,
    address _lockedPool,
    address _surfinWallet
  ) external initializer {
    require(_admin != address(0), "admin is zero address");
    require(_manager != address(0), "manager is zero address");
    require(_pauser != address(0), "pauser is zero address");
    require(_bot != address(0), "bot is zero address");
    require(_flexPool != address(0), "flexPool is zero address");
    require(_lockedPool != address(0), "lockedPool is zero address");
    require(_surfinWallet != address(0), "surfinWallet is zero address");
    require(ICreditFundPool(_flexPool).asset() == asset, "flexPool asset mismatch");
    require(ICreditFundPool(_lockedPool).asset() == asset, "lockedPool asset mismatch");

    __AccessControlEnumerable_init();
    __Pausable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);
    _grantRole(BOT, _bot);

    flexPool = _flexPool;
    lockedPool = _lockedPool;
    surfinWallet = _surfinWallet;

    // default hard floor: 3% of both pools' live book
    floorRate = 3 * 1e16;
    emit SetFloorRate(floorRate);
  }

  /* DEPLOY TO SURFIN */
  /**
   * @dev deploy idle funds to Surfin by transferring straight to Surfin's receiving
   *      wallet. Not split by product. Sensitive outflow, so gated to MANAGER
   *      (multisig). Blocked while paused and capped by the deployable amount.
   * @param amount the amount of asset to deploy
   */
  function deployToSurfin(uint256 amount) external onlyRole(MANAGER) whenNotPaused {
    require(amount > 0, "amount is zero");
    require(amount <= maxDeployToSurfin(), "exceeds deployable");

    deployedToSurfin += amount;

    IERC20(asset).safeTransfer(surfinWallet, amount);

    emit DeployToSurfin(amount);
  }

  /**
   * @dev weekly recall settlement (multisig). The manager transfers the recalled
   *      USDT into the adapter and, in one call: resets the Surfin book value,
   *      sets the platform fee earmark, covers the locked withdrawal queue, and
   *      leaves the remainder as buffer. Replaces repayFromSurfin + bookFee.
   *
   *      recalledAmount must cover everything this call consumes (locked cover +
   *      fee); the remainder (recalledAmount - lockedCoverAmount - feeAmount)
   *      stays on the adapter as buffer. deployedBookValue is an absolute reset,
   *      bidirectional: a recall lowers it, while 80% of Surfin interest rolling
   *      into principal raises it.
   * @param recalledAmount the recall USDT the manager transfers in (must approve first)
   * @param lockedCoverAmount amount to push into the locked pool's batch queue
   * @param feeAmount platform fee to earmark (Lista's share)
   * @param deployedBookValue the new absolute Surfin deployed book value
   */
  function settleRecall(
    uint256 recalledAmount,
    uint256 lockedCoverAmount,
    uint256 feeAmount,
    uint256 deployedBookValue
  ) external onlyRole(MANAGER) whenNotPaused {
    require(recalledAmount >= lockedCoverAmount + feeAmount, "recall insufficient");
    IERC20(asset).safeTransferFrom(msg.sender, address(this), recalledAmount);
    deployedToSurfin = deployedBookValue; // absolute reset (bidirectional)
    accruedFee += feeAmount; // fee earmark set by multisig
    if (lockedCoverAmount > 0) {
      _finishLockedWithdraw(lockedCoverAmount);
    }
    emit SettleRecall(recalledAmount, lockedCoverAmount, feeAmount, deployedBookValue);
  }

  /* REPAY POOL QUEUES */
  /**
   * @dev repay the flex pool's batch queue from idle funds. `amount` may be 0 to
   *      only advance batches.
   */
  function finishFlexWithdraw(uint256 amount) external onlyRole(BOT) {
    require(amount <= _availableForWithdraw(), "exceeds available");
    if (amount > 0) {
      IERC20(asset).safeIncreaseAllowance(flexPool, amount);
    }
    ICreditFundPool(flexPool).finishWithdraw(amount);
    emit FinishFlexWithdraw(amount);
  }

  /**
   * @dev repay the locked pool's batch queue (early-redeem + matured) from idle
   *      funds. BOT-callable so, if the weekly recall has not landed on time, the
   *      bot can still cover locked withdrawals out of the buffer pool. Bounded by
   *      the reserve guard (fee + hard floor) in _finishLockedWithdraw, which
   *      settleRecall also reuses.
   */
  function finishLockedWithdraw(uint256 amount) external onlyRole(BOT) {
    _finishLockedWithdraw(amount);
  }

  /* FUND INTEREST */
  /**
   * @dev fund the interest distributor from idle funds. Interest for both flex and
   *      locked users is paid off-pool through the cumulative Merkle distributor,
   *      so the adapter only tops it up; per-user amounts live in the merkle root.
   * @param amount the interest amount to fund
   */
  function fundInterest(uint256 amount) external onlyRole(MANAGER) {
    require(interestDistributor != address(0), "interestDistributor not set");
    require(amount > 0, "amount is zero");
    // Reserved: the flex queue, payable on demand from this same buffer. Not reserved:
    // the hard floor (it doubles as the interest reserve, so a drained floor only blocks
    // withdrawals until the next recall) and the locked maturity queue — see
    // onDemandUnfunded. Realized-yield accounting stays off-chain.
    require(amount <= _availableForInterest(), "insufficient idle");
    IERC20(asset).safeIncreaseAllowance(interestDistributor, amount);
    IInterestDistributor(interestDistributor).notifyReward(amount);
    emit FundInterest(amount);
  }

  /* PROFIT FEE (Lista share) */
  /**
   * @dev claim accrued fee to the fee receiver. BOT-callable so fee collection can
   *      be automated; funds can only move to the manager-set feeReceiver.
   */
  function claimFee(uint256 amount) external onlyRole(BOT) {
    require(feeReceiver != address(0), "feeReceiver is zero");
    require(amount > 0 && amount <= accruedFee, "invalid amount");
    accruedFee -= amount;
    IERC20(asset).safeTransfer(feeReceiver, amount);
    emit ClaimFee(feeReceiver, amount);
  }

  /* VIEWS */
  /**
   * @dev instantly-available liquidity held by the adapter (raw asset balance).
   */
  function idleBalance() public view returns (uint256) {
    return IERC20(asset).balanceOf(address(this));
  }

  /**
   * @dev freely usable idle funds after excluding the fee earmark.
   */
  function freeIdle() public view returns (uint256) {
    uint256 bal = idleBalance();
    return bal > accruedFee ? bal - accruedFee : 0;
  }

  /**
   * @dev floor base: both pools' live principal book, restored to the pre-burn level
   *      by adding back the pending withdrawals whose cash the adapter still holds.
   */
  function _floorBase() internal view returns (uint256) {
    return _poolFloorBase(flexPool) + _poolFloorBase(lockedPool);
  }

  /**
   * @dev one pool's contribution to the floor base.
   *
   * Requesting a withdrawal burns principal before the cash moves, so pending has to
   * backfill the base; once `finishWithdraw` pushes that cash into the pool it must
   * stop, or the adapter reserves against money it no longer holds — and a part-funded
   * batch wedges itself, floor unchanged while the balance that would clear it is gone.
   * `withdrawQuota + totalConfirmedUnclaimed` is the pool's balance, i.e. exactly what
   * left here. Clamped, not checked: `adminTopUp` injects quota outside the usual bound
   * and `hardFloor()` must not revert on an impaired fund.
   */
  function _poolFloorBase(address pool) internal view returns (uint256) {
    return ICreditFundPool(pool).totalPrincipal() + _poolUnfunded(pool);
  }

  /**
   * @dev the unfunded half of one pool's queue. Shared by the floor base, the deploy
   *      ceiling and the interest cap; they differ only in which pools they aggregate.
   */
  function _poolUnfunded(address pool) internal view returns (uint256) {
    ICreditFundPool p = ICreditFundPool(pool);
    uint256 pending = p.totalPendingWithdraw();
    uint256 funded = p.withdrawQuota() + p.totalConfirmedUnclaimed();
    return pending > funded ? pending - funded : 0;
  }

  /**
   * @dev on-chain hard floor (3% of the floor base). Never paid out for flex/locked
   *      withdrawals; doubles as the interest reserve.
   */
  function hardFloor() public view returns (uint256) {
    return (_floorBase() * floorRate) / PRECISION;
  }

  /**
   * @dev principal both pools have queued and still need cash for. Cash already pushed
   *      into a pool (confirmed-unclaimed, or quota awaiting a batch) is excluded — it
   *      has left the adapter and is no longer ours to reserve.
   */
  function unfundedWithdrawals() public view returns (uint256) {
    return _poolUnfunded(flexPool) + _poolUnfunded(lockedPool);
  }

  /**
   * @dev the queue slice that must be payable on demand out of idle cash: the flex pool
   *      only. The locked MATURITY queue is settled from the recall earmarked for it, so
   *      reserving it here books the same obligation twice — it froze interest funding
   *      (for every user, flex included) and deployment for the whole maturity-to-recall
   *      gap, and no in-pool action could clear it: feeding the queue lowers idle and the
   *      reservation equally. Early redemptions ride along, being indistinguishable
   *      on-chain. deployToSurfin stays MANAGER-gated, so holding back while maturities
   *      are outstanding remains an operating choice rather than a hard block.
   */
  function onDemandUnfunded() public view returns (uint256) {
    return _poolUnfunded(flexPool);
  }

  /**
   * @dev max amount deployable to Surfin: free idle (already net of the fee earmark)
   *      less the hard floor and the queued withdrawals still owed cash.
   *
   * Requesting a withdrawal only moves accounting from principal into
   * totalPendingWithdraw, so a ceiling blind to it would let the manager deploy the very
   * cash meant to pay a queued exit, leaving the BOT unable to fund it until the next
   * recall. Reserving the unfunded obligation is not double-counting against the floor:
   * the floor reserves a percentage of the whole book, while this reserves 100% of what
   * is already queued.
   *
   * The larger off-chain buffer target is still the multisig's job when sizing a
   * deploy; on-chain we only guarantee the queue stays fundable.
   */
  function maxDeployToSurfin() public view returns (uint256) {
    uint256 free = freeIdle();
    uint256 reserved = hardFloor() + onDemandUnfunded();
    return free > reserved ? free - reserved : 0;
  }

  /**
   * @dev informational: instantly withdrawable amount payable to users, i.e. cash
   *      above the protected reserve (fee + hard floor).
   */
  function instantWithdrawable() external view returns (uint256) {
    return _availableForWithdraw();
  }

  /* MANAGER FUNCTIONS */
  /// @dev emergency stop for outbound flows (deploy to Surfin)
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  /// @dev lift the emergency stop
  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function setFloorRate(uint256 _floorRate) external onlyRole(MANAGER) {
    require(_floorRate <= PRECISION, "invalid floor rate");
    floorRate = _floorRate;
    emit SetFloorRate(_floorRate);
  }

  function setSurfinWallet(address _surfinWallet) external onlyRole(MANAGER) {
    require(_surfinWallet != address(0), "surfinWallet is zero address");
    surfinWallet = _surfinWallet;
    emit SetSurfinWallet(_surfinWallet);
  }

  function setInterestDistributor(address _interestDistributor) external onlyRole(MANAGER) {
    require(_interestDistributor != address(0), "interestDistributor is zero address");
    require(IInterestDistributor(_interestDistributor).token() == asset, "distributor asset mismatch");
    interestDistributor = _interestDistributor;
    emit SetInterestDistributor(_interestDistributor);
  }

  function setFeeReceiver(address _feeReceiver) external onlyRole(MANAGER) {
    require(_feeReceiver != address(0), "feeReceiver is zero");
    feeReceiver = _feeReceiver;
    emit SetFeeReceiver(_feeReceiver);
  }

  /**
   * @dev emergency token rescue by admin.
   */
  function emergencyWithdraw(address token, uint256 amount, address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(amount > 0, "amount is zero");
    require(receiver != address(0), "receiver is zero address");
    IERC20(token).safeTransfer(receiver, amount);
    emit EmergencyWithdraw(token, receiver, amount);
  }

  /* INTERNAL FUNCTIONS */
  /**
   * @dev cash payable for flex/locked withdrawals: on-adapter balance minus the
   *      protected reserve (fee earmark + hard floor).
   */
  function _availableForWithdraw() internal view returns (uint256) {
    uint256 cash = idleBalance();
    uint256 protectedAmt = accruedFee + hardFloor();
    return cash > protectedAmt ? cash - protectedAmt : 0;
  }

  /**
   * @dev cash payable as interest: free idle less the queued withdrawals still owed
   *      cash. Deliberately does NOT subtract the hard floor — the floor is the
   *      interest reserve and interest is the one flow allowed to consume it.
   */
  function _availableForInterest() internal view returns (uint256) {
    uint256 free = freeIdle();
    uint256 reserved = onDemandUnfunded();
    return free > reserved ? free - reserved : 0;
  }

  /**
   * @dev shared locked-queue repay path, bounded by the reserve guard. Reused by
   *      finishLockedWithdraw (BOT) and settleRecall.
   */
  function _finishLockedWithdraw(uint256 amount) internal {
    require(amount <= _availableForWithdraw(), "exceeds available");
    if (amount > 0) {
      IERC20(asset).safeIncreaseAllowance(lockedPool, amount);
    }
    ICreditFundPool(lockedPool).finishWithdraw(amount);
    emit FinishLockedWithdraw(amount);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  uint256[50] private __gap;
}
