// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

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
  using Math for uint256;

  /* VARIABLES */
  // flex (demand) pool
  address public flexPool;
  // locked (term) pool
  address public lockedPool;
  // Surfin receiving wallet (off-chain custody/multisig that funds are deployed to)
  address public surfinWallet;
  // interest distributor (cumulative Merkle interest payouts)
  address public interestDistributor;

  // accrued Lista profit fee earmark; withdrawable by manager only
  uint256 public accruedFee;
  // book value currently deployed to Surfin
  uint256 public deployedToSurfin;

  // single hard-floor rate over both pools' live book, 1e18 (e.g. 0.03e18 = 3%).
  // The 15% buffer target is maintained off-chain; only the hard floor is enforced
  // on-chain (also doubles as the interest reserve).
  uint256 public floorRate;

  // last cycle (week) a deploy happened
  uint256 public deployCycle;
  // last cycle (week) a recall/settlement happened; blocks deploy in the same cycle
  uint256 public recallCycle;

  // profit fee receiver and rate (1e18); rate is informational for off-chain sizing
  address public feeReceiver;
  uint256 public feeRate;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  uint256 public constant PRECISION = 1e18;
  uint256 public constant MAX_FEE_RATE = 3 * 1e17; // 30%

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
  event SetFeeRate(uint256 feeRate);
  event EmergencyWithdraw(address token, uint256 amount);

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
  }

  /* DEPLOY TO SURFIN */
  /**
   * @dev deploy idle funds to Surfin by transferring straight to Surfin's receiving
   *      wallet. Not split by product. Sensitive outflow, so gated to MANAGER
   *      (multisig). Blocked while paused, capped by the deployable amount, and the
   *      net-flow rule (no deploy in a cycle that already recalled).
   * @param amount the amount of asset to deploy
   */
  function deployToSurfin(uint256 amount) external onlyRole(MANAGER) whenNotPaused {
    require(amount > 0, "amount is zero");
    require(amount <= maxDeployToSurfin(), "exceeds deployable");

    uint256 cycle = block.timestamp / 1 weeks;
    require(recallCycle != cycle, "recalled this cycle");
    deployCycle = cycle;

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
    recallCycle = block.timestamp / 1 weeks; // block deploy in the same cycle
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
  function fundInterest(uint256 amount) external onlyRole(BOT) {
    require(interestDistributor != address(0), "interestDistributor not set");
    require(amount > 0, "amount is zero");
    // interest may consume the hard floor (floor doubles as the interest reserve);
    // only the fee earmark is protected. A drained floor blocks flex withdrawals
    // via _availableForWithdraw until the next weekly recall tops it back up.
    uint256 bal = IERC20(asset).balanceOf(address(this));
    require(amount <= (bal > accruedFee ? bal - accruedFee : 0), "insufficient idle");
    IERC20(asset).safeIncreaseAllowance(interestDistributor, amount);
    IInterestDistributor(interestDistributor).notifyReward(asset, amount);
    emit FundInterest(amount);
  }

  /* PROFIT FEE (Lista share) */
  /**
   * @dev claim accrued fee to the fee receiver.
   */
  function claimFee(uint256 amount) external onlyRole(MANAGER) {
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
   * @dev floor base: both pools' live principal book, restored to the pre-burn
   *      level by adding totalPendingWithdraw (principal is decremented at request
   *      time, but the cash only leaves the adapter at finishWithdraw).
   */
  function _floorBase() internal view returns (uint256) {
    return ICreditFundPool(flexPool).totalPrincipal() +
      ICreditFundPool(flexPool).totalPendingWithdraw() +
      ICreditFundPool(lockedPool).totalPrincipal() +
      ICreditFundPool(lockedPool).totalPendingWithdraw();
  }

  /**
   * @dev on-chain hard floor (3% of the floor base). Never paid out for flex/locked
   *      withdrawals; doubles as the interest reserve.
   */
  function hardFloor() public view returns (uint256) {
    return (_floorBase() * floorRate) / PRECISION;
  }

  /**
   * @dev max amount deployable to Surfin: everything above the hard floor (free idle
   *      already excludes the fee earmark). The 15% buffer / pending-withdrawal
   *      liquidity is maintained off-chain by the multisig when sizing the deploy;
   *      on-chain only the hard floor is reserved.
   */
  function maxDeployToSurfin() public view returns (uint256) {
    uint256 free = freeIdle();
    uint256 floor = hardFloor();
    return free > floor ? free - floor : 0;
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
    interestDistributor = _interestDistributor;
    emit SetInterestDistributor(_interestDistributor);
  }

  function setFeeReceiver(address _feeReceiver) external onlyRole(MANAGER) {
    require(_feeReceiver != address(0), "feeReceiver is zero");
    feeReceiver = _feeReceiver;
    emit SetFeeReceiver(_feeReceiver);
  }

  function setFeeRate(uint256 _feeRate) external onlyRole(MANAGER) {
    require(_feeRate <= MAX_FEE_RATE, "feeRate too high");
    feeRate = _feeRate;
    emit SetFeeRate(_feeRate);
  }

  /**
   * @dev emergency token rescue by admin.
   */
  function emergencyWithdraw(address token, uint256 amount, address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(amount > 0, "amount is zero");
    require(receiver != address(0), "receiver is zero address");
    IERC20(token).safeTransfer(receiver, amount);
    emit EmergencyWithdraw(token, amount);
  }

  /* INTERNAL FUNCTIONS */
  /**
   * @dev cash payable for flex/locked withdrawals: on-adapter balance minus the
   *      protected reserve (fee earmark + hard floor).
   */
  function _availableForWithdraw() internal view returns (uint256) {
    uint256 cash = IERC20(asset).balanceOf(address(this));
    uint256 protectedAmt = accruedFee + hardFloor();
    return cash > protectedAmt ? cash - protectedAmt : 0;
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
}
