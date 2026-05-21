// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IXAUTStaking } from "./interface/IXAUTStaking.sol";
import { IXAUEFundToken } from "./interface/IXAUEFundToken.sol";
import { IXAUEOracle } from "./interface/IXAUEOracle.sol";

/**
 * @title XAUEAdapter
 * @notice Bridges XAUTStaking ↔ XAUE Protocol. Holds Lista's XAUE share balance; detects profit
 *         (NAV growth on those shares) and pushes net interest to XAUTStaking via increaseTotalAssets().
 *
 *         XAUE's interface differs from ERC-7540:
 *         - mint() is synchronous (sync mint, returns shares immediately)
 *         - requestRedemption() is async step 1 (shares burn here, asset locked at NAV)
 *         - XAUE REDEMPTION_APPROVER then calls approveRedemption (asset → this adapter)
 *
 *         Phase 1 does NOT handle rejectRedemption (XAUE side path, manager-only, rarely triggered).
 *         Off-chain monitoring covers BOT and XAUE state.
 */
contract XAUEAdapter is AccessControlEnumerableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;
  using Math for uint256;

  /* VARIABLES */
  /// @notice XAUE FundToken (CoboFundToken)
  address public xaueFundToken;
  /// @notice XAUE Oracle (returns NAV at 1e18 scale)
  address public xaueOracle;
  /// @notice XAUTStaking — receives interest & withdrawal funds
  address public staking;
  /// @notice Fee recipient (XAUT)
  address public feeReceiver;
  /// @notice Protocol fee rate on XAUE NAV profit, 1e18 precision (e.g. 0.2e18 = 20%)
  uint256 public feeRate;
  /// @notice Accumulated XAUT fee, unclaimed
  uint256 public fee;
  /// @notice Last seen XAUT-value of adapter's XAUE holdings (6-dec)
  uint256 public lastVaultTotalAssets;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  uint256 public constant PRECISION = 1e18;
  uint256 public constant MAX_FEE_RATE = 0.3e18; // 30%
  /// @notice Hard cap on per-update absolute change in totalVaultAssets, in basis points.
  ///         10% — defends against oracle anomalies. Per XAUE Oracle design (maxAprDelta=5%/update,
  ///         minUpdateInterval=1 day), a healthy NAV move never approaches this cap.
  ///         If exceeded, MANAGER must investigate and unblock via pause + emergencyWithdraw + upgrade.
  uint256 public constant MAX_DELTA_BPS = 1000;

  /* IMMUTABLE */
  /// @notice XAUT token (6-dec, the underlying for both XAUTStaking and XAUE Protocol)
  address public immutable asset;

  /* EVENTS */
  event DepositToVault(uint256 assetAmount, uint256 shareAmount);
  event RequestRedeemFromVault(uint256 indexed reqId, uint256 assetAmount, uint256 shareAmount);
  event ClaimFee(address feeReceiver, uint256 feeAmount);
  event UpdateVaultAssets(uint256 newTotal, uint256 totalInterest, uint256 interestFee, uint256 netInterest);
  event VaultLoss(uint256 newTotal, uint256 totalLoss);
  event SetFeeReceiver(address feeReceiver);
  event SetFeeRate(uint256 feeRate);
  event SetStaking(address staking);
  event SetXAUEFundToken(address xaueFundToken);
  event SetXAUEOracle(address xaueOracle);
  event EmergencyWithdraw(address token, uint256 amount);

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param _asset XAUT address (immutable; same for both sides)
  constructor(address _asset) {
    require(_asset != address(0), "asset is zero");
    _disableInitializers();
    asset = _asset;
  }

  /* INITIALIZER */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _staking,
    address _xaueFundToken,
    address _xaueOracle
  ) public initializer {
    require(_admin != address(0), "admin is zero");
    require(_manager != address(0), "manager is zero");
    require(_bot != address(0), "bot is zero");
    require(_staking != address(0), "staking is zero");
    require(_xaueFundToken != address(0), "xaueFundToken is zero");
    require(_xaueOracle != address(0), "xaueOracle is zero");

    __AccessControl_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(BOT, _bot);

    staking = _staking;
    xaueFundToken = _xaueFundToken;
    xaueOracle = _xaueOracle;

    emit SetStaking(_staking);
    emit SetXAUEFundToken(_xaueFundToken);
    emit SetXAUEOracle(_xaueOracle);
  }

  /* BOT ENTRY POINTS */

  /**
   * @notice Move pending XAUT (sitting on this adapter) into XAUE via XAUE.mint() — synchronous.
   *         XAUT leaves adapter → XAUE Vault; XAUE shares mint to adapter.
   */
  function depositToVault(uint256 assetAmount) external onlyRole(BOT) nonReentrant {
    require(assetAmount > 0, "amount is zero");

    _updateVaultAssets();

    IERC20(asset).safeIncreaseAllowance(xaueFundToken, assetAmount);
    uint256 sharesReceived = IXAUEFundToken(xaueFundToken).mint(assetAmount);
    IERC20(asset).forceApprove(xaueFundToken, 0);

    lastVaultTotalAssets = getVaultTotalAssets();
    emit DepositToVault(assetAmount, sharesReceived);
  }

  /**
   * @notice Request XAUE to redeem enough XAUE shares to recover `assetAmount` of XAUT. The function
   *         converts XAUT to XAUE share count at current NAV (rounded up so the redemption recovers
   *         at least `assetAmount`), then calls XAUE.requestRedemption. XAUE burns adapter's shares
   *         and locks the exact assetAmount based on its own NAV read in the same tx; the redemption
   *         settlement (XAUT → adapter) happens off-chain via XAUE's REDEMPTION_APPROVER.
   * @param assetAmount Target XAUT amount to recover (6-dec)
   */
  function requestWithdrawFromVault(uint256 assetAmount) external onlyRole(BOT) nonReentrant {
    require(assetAmount > 0, "amount is zero");

    _updateVaultAssets();

    // shareAmount = ceil(assetAmount × 1e30 / nav). Ceil rounding ensures we redeem at least assetAmount.
    uint256 nav = IXAUEOracle(xaueOracle).getLatestPrice();
    require(nav > 0, "zero nav");
    uint256 shareAmount = assetAmount.mulDiv(1e30, nav, Math.Rounding.Ceil);
    // Defensive pre-check: surfaces a local error instead of relying on XAUE's revert.
    require(shareAmount >= IXAUEFundToken(xaueFundToken).minRedeemShares(), "below xaue minRedeem");

    uint256 reqId = IXAUEFundToken(xaueFundToken).requestRedemption(shareAmount);

    lastVaultTotalAssets = getVaultTotalAssets();
    emit RequestRedeemFromVault(reqId, assetAmount, shareAmount);
  }

  /**
   * @notice Forward XAUT held by this adapter (received from XAUE approveRedemption) to XAUTStaking
   *         so it can confirm pending batches. Pass amount=0 to just tick the batch state on the
   *         staking side without delivering new funds.
   */
  function finishEarnPoolWithdraw(uint256 amount) external onlyRole(BOT) nonReentrant {
    if (amount > 0) {
      IERC20(asset).safeIncreaseAllowance(staking, amount);
    }
    IXAUTStaking(staking).finishWithdraw(amount);
    if (amount > 0) {
      IERC20(asset).forceApprove(staking, 0);
    }
  }

  /**
   * @notice Claim accumulated fee in XAUT to feeReceiver. Adapter must hold enough XAUT balance
   *         (typically because some recently approved redemption left fee XAUT sitting here).
   */
  function claimFee(uint256 feeAmount) external onlyRole(BOT) nonReentrant {
    require(feeAmount > 0, "amount is zero");
    require(feeReceiver != address(0), "feeReceiver is zero");
    require(fee >= feeAmount, "exceeds accumulated fee");
    require(IERC20(asset).balanceOf(address(this)) >= feeAmount, "insufficient balance");

    fee -= feeAmount;
    IERC20(asset).safeTransfer(feeReceiver, feeAmount);
    emit ClaimFee(feeReceiver, feeAmount);
  }

  /**
   * @notice Permissionless sync of NAV-based profit/loss accounting. Called by:
   *         - BOT periodically (heartbeat)
   *         - XAUTStaking on every deposit / requestWithdraw (front-run mitigation; audit B/H-01)
   *         - anyone, at no cost to the system (idempotent within a tx via nonReentrant + NAV reread)
   */
  function updateVaultAssets() external nonReentrant {
    _updateVaultAssets();
  }

  /* VIEW */

  /// @notice Current XAUT-equivalent value of adapter's XAUE share holdings (6-dec).
  function getVaultTotalAssets() public view returns (uint256) {
    uint256 shareBalance = IERC20(xaueFundToken).balanceOf(address(this));
    uint256 nav = IXAUEOracle(xaueOracle).getLatestPrice();
    // XAUT-wei = shareBalance × nav / 1e30  (shareBalance 18-dec × nav 1e18 / 1e30 = 6-dec)
    return shareBalance.mulDiv(nav, 1e30);
  }

  /* MANAGER */

  function setFeeReceiver(address _feeReceiver) external onlyRole(MANAGER) {
    require(_feeReceiver != address(0), "feeReceiver is zero");
    feeReceiver = _feeReceiver;
    emit SetFeeReceiver(_feeReceiver);
  }

  function setFeeRate(uint256 _feeRate) external onlyRole(MANAGER) {
    require(_feeRate <= MAX_FEE_RATE, "fee rate too high");
    feeRate = _feeRate;
    emit SetFeeRate(_feeRate);
  }

  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    require(amount > 0, "amount is zero");
    IERC20(token).safeTransfer(msg.sender, amount);
    emit EmergencyWithdraw(token, amount);
  }

  /* INTERNAL */

  /**
   * @dev Reconcile XAUE NAV movement against staking-side accounting.
   *      - NAV up (profit): charge feeRate% to `fee`, push remainder to staking as interest.
   *      - NAV down (loss): push the full loss to staking; users bear it pro-rata via convertRate.
   *        Fee is NOT clawed back (already credited on past upside).
   *
   *      Per-update absolute delta is capped at `MAX_DELTA_BPS` (10%) of `lastVaultTotalAssets`.
   *      Defends against oracle anomalies (unrealistically high or low NAV reads). If exceeded,
   *      the call reverts — MANAGER must investigate before any further state changes proceed.
   */
  function _updateVaultAssets() private {
    uint256 newVaultTotalAssets = getVaultTotalAssets();
    if (newVaultTotalAssets > lastVaultTotalAssets) {
      uint256 totalInterest = newVaultTotalAssets - lastVaultTotalAssets;
      // Sanity bound: cap per-update growth at MAX_DELTA_BPS of base.
      require(totalInterest * 10000 <= lastVaultTotalAssets * MAX_DELTA_BPS, "delta exceeds max");
      uint256 interestFee = totalInterest.mulDiv(feeRate, PRECISION);
      fee += interestFee;
      uint256 netInterest = totalInterest - interestFee;
      if (netInterest > 0) {
        IXAUTStaking(staking).increaseTotalAssets(netInterest);
      }
      emit UpdateVaultAssets(newVaultTotalAssets, totalInterest, interestFee, netInterest);
    } else if (newVaultTotalAssets < lastVaultTotalAssets) {
      uint256 totalLoss = lastVaultTotalAssets - newVaultTotalAssets;
      // Sanity bound: cap per-update decline at MAX_DELTA_BPS of base (symmetric protection).
      require(totalLoss * 10000 <= lastVaultTotalAssets * MAX_DELTA_BPS, "delta exceeds max");
      IXAUTStaking(staking).decreaseTotalAssets(totalLoss);
      emit VaultLoss(newVaultTotalAssets, totalLoss);
    }
    lastVaultTotalAssets = newVaultTotalAssets;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
