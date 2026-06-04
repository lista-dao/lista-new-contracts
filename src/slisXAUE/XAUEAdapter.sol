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
 *         - XAUE REDEMPTION_APPROVER may instead reject; shares are re-minted back to adapter.
 *
 *         Accounting baseline: NAV math runs against `expectedShareBalance` (the share count adapter
 *         knows it owns), NOT the raw `balanceOf(this)`. Unsolicited dust transfers and not-yet-acked
 *         reject shares therefore have zero effect on NAV / fee / interest until MANAGER explicitly
 *         brings them in. `_updateVaultAssets` tolerates EXCESS actual (`balanceOf >= expectedShareBalance`)
 *         but fail-closes on a DEFICIT — actual < expected would imply we'd be crediting interest on
 *         shares we don't actually hold, so the function reverts and MANAGER must reconcile.
 *
 *         Reject handling: after XAUE rejects a redemption, BOT calls `acknowledgeReject(reqId)`.
 *         It is a pure accounting bump — `expectedShareBalance += shareAmount` and
 *         `lastVaultTotalAssets += lockedAssetAmount` (request-time XAUT value). No interest /
 *         loss is pushed in this call. Any pending NAV delta (active slice since last sync +
 *         the rejected slice's in-flight delta) surfaces as a normal `getVault - lastVault`
 *         delta on the next `_updateVaultAssets` and is handled by the standard fee + cap +
 *         totalSupply-zero path. The `rejectAcknowledged[reqId]` map enforces one-shot ack.
 *
 *         User-side compensation (slisXAUE already burned at requestWithdraw) is out-of-scope here and
 *         handled via Lista off-chain runbook (M-05).
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
  /// @notice slisXAUE share token. Cached at initialize to avoid an extra cross-contract hop on
  ///         every NAV sync (`_pushInterest` needs `totalSupply` for the no-holders
  ///         protocol-surplus branch).
  address public slisXAUE;
  /// @notice Fee recipient (XAUT)
  address public feeReceiver;
  /// @notice Protocol fee rate on XAUE NAV profit, 1e18 precision (e.g. 0.2e18 = 20%)
  uint256 public feeRate;
  /// @notice Accumulated XAUT fee, unclaimed
  uint256 public fee;
  /// @notice Last seen XAUT-value of adapter's XAUE holdings (6-dec)
  uint256 public lastVaultTotalAssets;
  /// @notice XAUE share count adapter has explicitly minted (or had credited back via acknowledgeReject).
  ///         The sole basis for NAV math in `getVaultTotalAssets`; drift between this and
  ///         `balanceOf(this)` is tolerated (dust / not-yet-acked reject extras) and does NOT affect
  ///         interest / loss propagation to staking until MANAGER brings the extras in via
  ///         `acknowledgeReject` (or removes them via `emergencyWithdraw`).
  uint256 public expectedShareBalance;
  /// @notice MANAGER-tunable cap on per-update absolute change in totalVaultAssets, basis points.
  ///         Defaults to 1000 (10%); upper bound MAX_DELTA_BPS_CAP (3000 = 30%) keeps MANAGER
  ///         from making the bound meaningless. Defends against oracle anomalies; per XAUE Oracle
  ///         design (maxAprDelta=5%/update, minUpdateInterval=1 day) a healthy NAV move never
  ///         approaches this cap. If exceeded, the call reverts -- MANAGER must investigate.
  uint256 public maxDeltaBps;
  /// @notice Per-reqId guard: prevents `acknowledgeReject` from re-crediting the same rejected
  ///         redemption when multiple rejects are outstanding (the actualShares >= expected+amount
  ///         check is satisfiable twice for the same reqId if other unack'd rejects exist).
  mapping(uint256 => bool) public rejectAcknowledged;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  uint256 public constant PRECISION = 1e18;
  uint256 public constant MAX_FEE_RATE = 0.3e18; // 30%
  /// @notice Upper bound on `maxDeltaBps` to keep the sanity cap meaningful (30%).
  uint256 public constant MAX_DELTA_BPS_CAP = 3000;
  /// @notice Default value of `maxDeltaBps` set at initialize time.
  uint256 public constant DEFAULT_MAX_DELTA_BPS = 1000;
  /// @notice XAUE FundToken's RedemptionStatus.Rejected enum value
  uint8 public constant REDEMPTION_STATUS_REJECTED = 1;

  /* IMMUTABLE */
  /// @notice XAUT token (6-dec, the underlying for both XAUTStaking and XAUE Protocol)
  address public immutable asset;

  /* EVENTS */
  event DepositToVault(uint256 assetAmount, uint256 shareAmount);
  event RequestRedeemFromVault(uint256 indexed reqId, uint256 assetAmount, uint256 shareAmount);
  event ClaimFee(address feeReceiver, uint256 feeAmount);
  event UpdateVaultAssets(uint256 newTotal, uint256 totalInterest, uint256 interestFee, uint256 netInterest);
  event SetFeeReceiver(address feeReceiver);
  event SetFeeRate(uint256 feeRate);
  event SetStaking(address staking);
  event SetSlisXAUE(address slisXAUE);
  event SetXAUEFundToken(address xaueFundToken);
  event SetXAUEOracle(address xaueOracle);
  event SetMaxDeltaBps(uint256 oldBps, uint256 newBps);
  event RedemptionRejectAcknowledged(uint256 indexed reqId, uint256 shareAmount);
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
  /**
   * @dev `staking` is NOT set here because XAUTStaking init requires the adapter address (circular
   *      dep at construction time). MANAGER wires it in via `setStaking` after all three proxies
   *      are deployed. BOT entry points (depositToVault, requestWithdrawFromVault,
   *      finishEarnPoolWithdraw, acknowledgeReject) all touch `staking`, so they will revert until
   *      it is set — surfaces a configuration error loudly.
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _slisXAUE,
    address _xaueFundToken,
    address _xaueOracle,
    address _feeReceiver,
    uint256 _feeRate
  ) public initializer {
    require(_admin != address(0), "admin is zero");
    require(_manager != address(0), "manager is zero");
    require(_bot != address(0), "bot is zero");
    require(_slisXAUE != address(0), "slisXAUE is zero");
    require(_xaueFundToken != address(0), "xaueFundToken is zero");
    require(_xaueOracle != address(0), "xaueOracle is zero");
    require(_feeReceiver != address(0), "feeReceiver is zero");
    require(_feeRate <= MAX_FEE_RATE, "fee rate too high");

    __AccessControl_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(BOT, _bot);

    slisXAUE = _slisXAUE;
    xaueFundToken = _xaueFundToken;
    xaueOracle = _xaueOracle;
    feeReceiver = _feeReceiver;
    feeRate = _feeRate;
    maxDeltaBps = DEFAULT_MAX_DELTA_BPS;

    emit SetSlisXAUE(_slisXAUE);
    emit SetXAUEFundToken(_xaueFundToken);
    emit SetXAUEOracle(_xaueOracle);
    emit SetFeeReceiver(_feeReceiver);
    emit SetFeeRate(_feeRate);
    emit SetMaxDeltaBps(0, DEFAULT_MAX_DELTA_BPS);
  }

  /* BOT ENTRY POINTS */

  /**
   * @notice Move pending XAUT (sitting on this adapter) into XAUE via XAUE.mint() — synchronous.
   *         XAUT leaves adapter → XAUE Vault; XAUE shares mint to adapter.
   */
  function depositToVault(uint256 assetAmount) external onlyRole(BOT) nonReentrant {
    require(assetAmount > 0, "amount is zero");
    // Surface XAUE's own deposit floor at the adapter boundary instead of reverting deep inside
    // mint(), mirroring the min-redeem pre-check in requestWithdrawFromVault. (Bailsec 25)
    require(assetAmount >= IXAUEFundToken(xaueFundToken).minDepositAmount(), "below xaue minDeposit");

    _updateVaultAssets();

    IERC20(asset).safeIncreaseAllowance(xaueFundToken, assetAmount);
    uint256 sharesReceived = IXAUEFundToken(xaueFundToken).mint(assetAmount);
    IERC20(asset).forceApprove(xaueFundToken, 0);

    expectedShareBalance += sharesReceived;
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

    expectedShareBalance -= shareAmount;
    lastVaultTotalAssets = getVaultTotalAssets();
    emit RequestRedeemFromVault(reqId, assetAmount, shareAmount);
  }

  /**
   * @notice Forward XAUT held by this adapter (received from XAUE approveRedemption) to XAUTStaking so
   *         it can confirm pending batches. Pass `amount=0` to just tick batch state without delivering
   *         new funds.
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

  /// @notice Canonical XAUT-equivalent value of adapter's XAUE share holdings (6-dec).
  ///         Uses `expectedShareBalance` instead of `balanceOf(this)` so unsolicited dust transfers
  ///         and not-yet-acknowledged reject shares do NOT bleed into NAV accounting. Drift between
  ///         expected and actual is therefore harmless to staking-side accounting; MANAGER reconciles
  ///         only when shares need to be brought in (acknowledgeReject) or removed (emergencyWithdraw).
  function getVaultTotalAssets() public view returns (uint256) {
    uint256 nav = IXAUEOracle(xaueOracle).getLatestPrice();
    // XAUT-wei = expectedShareBalance × nav / 1e30  (shares 18-dec × nav 1e18 / 1e30 = 6-dec)
    return expectedShareBalance.mulDiv(nav, 1e30);
  }

  /* MANAGER */

  function setFeeReceiver(address _feeReceiver) external onlyRole(MANAGER) {
    require(_feeReceiver != address(0), "feeReceiver is zero");
    feeReceiver = _feeReceiver;
    emit SetFeeReceiver(_feeReceiver);
  }

  function setFeeRate(uint256 _feeRate) external onlyRole(MANAGER) {
    require(_feeRate <= MAX_FEE_RATE, "fee rate too high");
    // Settle accrued NAV at the OLD rate before switching, so the new rate only applies to gains that
    // accrue afterward (no hindsight re-taxing of the pending delta). (Bailsec 15)
    _updateVaultAssets();
    feeRate = _feeRate;
    emit SetFeeRate(_feeRate);
  }

  function setMaxDeltaBps(uint256 _maxDeltaBps) external onlyRole(MANAGER) {
    require(_maxDeltaBps > 0, "maxDeltaBps is zero");
    require(_maxDeltaBps <= MAX_DELTA_BPS_CAP, "maxDeltaBps too high");
    // When LOWERING the cap, settle the accrued delta under the current (higher) cap first, so a
    // pending in-cap move books before the tighter cap takes effect and can't freeze the next
    // sync-first flow. When RAISING, do NOT sync first: that path exists precisely to clear a backlog
    // whose delta exceeds the current cap, and a pre-sync would revert and block the raise. (Bailsec 18)
    if (_maxDeltaBps < maxDeltaBps) {
      _updateVaultAssets();
    }
    uint256 old = maxDeltaBps;
    maxDeltaBps = _maxDeltaBps;
    emit SetMaxDeltaBps(old, _maxDeltaBps);
  }

  /**
   * @notice Repoint the XAUE oracle (e.g. when XAUE migrates the oracle its FundToken uses). Settles
   *         accrued NAV under the OLD oracle, switches, then re-baselines `lastVaultTotalAssets`
   *         against the NEW oracle so the change of pricing BASIS is not mis-booked as interest/loss.
   *         A real cross-oracle discrepancy is an anomaly for MANAGER to reconcile, not yield. Has
   *         broad side-effects; use only to mirror an XAUE oracle migration. (Bailsec 16)
   */
  function setXAUEOracle(address _xaueOracle) external onlyRole(MANAGER) {
    require(_xaueOracle != address(0), "xaueOracle is zero");
    _updateVaultAssets();
    xaueOracle = _xaueOracle;
    lastVaultTotalAssets = getVaultTotalAssets();
    emit SetXAUEOracle(_xaueOracle);
  }

  /**
   * @notice Wire the XAUTStaking address after deployment. `staking` is intentionally NOT set in
   *         `initialize` because of the circular construction-time dep (staking init wants the
   *         adapter address). Deploy script flow: deploy all three proxies → call `setStaking`.
   *         MANAGER-restricted; can be re-pointed during operations / migrations.
   */
  function setStaking(address _staking) external onlyRole(MANAGER) {
    require(_staking != address(0), "staking is zero");
    staking = _staking;
    emit SetStaking(_staking);
  }

  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    require(amount > 0, "amount is zero");
    IERC20(token).safeTransfer(msg.sender, amount);
    emit EmergencyWithdraw(token, amount);
  }

  /**
   * @notice Acknowledge that XAUE rejected redemption `reqId` and re-credit the returned shares into
   *         the adapter's accounting baseline. shareAmount and lockedAssetAmount are read from XAUE's
   *         public `redemptions(reqId)` getter so adapter doesn't duplicate XAUE state.
   * @dev    Validates (1) reqId hasn't already been acknowledged, (2) reqId belongs to this adapter,
   *         (3) XAUE marks it as Rejected, and (4) the adapter's actual XAUE share balance is at
   *         least `expectedShareBalance + shareAmount`. `>=` lets BOT drain multiple rejects in any
   *         order; the explicit `rejectAcknowledged` map prevents the balance check from being
   *         satisfied twice for the same reqId when other unack'd rejects inflate `actualShares`.
   *
   *         BOT-callable because every validation above is on-chain — the function fail-closes on
   *         missing precondition (wrong reqId owner, wrong status, share-delta mismatch) so there
   *         is no manual decision to make. BOT monitors XAUE for RedemptionRejected events and
   *         calls this in response.
   *
   *         Accounting: re-credit the rejected shares as PRINCIPAL at request-time NAV
   *         (= XAUE's `lockedAssetAmount`): `expectedShareBalance += shareAmount`,
   *         `lastVaultTotalAssets += lockedAssetAmount`. Any NAV delta (both the un-rejected
   *         slice's delta since last sync AND the rejected slice's in-flight delta) surfaces as
   *         `getVault - lastVault` on the next `_updateVaultAssets` and goes through the standard
   *         fee + cap + totalSupply-zero machinery in a single push.
   *
   *         The combined delta is normally well under maxDeltaBps (BOT heartbeat keeps active-slice
   *         delta small per sync, and XAUE Oracle moves at most ~5%/day). If a long heartbeat
   *         outage + reject pushes the combined delta over cap, MANAGER can temporarily raise
   *         `maxDeltaBps` via `setMaxDeltaBps` to clear the backlog.
   *
   *         User-side compensation (slisXAUE was already burned in XAUTStaking.requestWithdraw and the
   *         WithdrawalRequest sits in queue) is handled off-chain via Lista runbook (M-05).
   * @param reqId The XAUE redemption request id that was rejected
   */
  function acknowledgeReject(uint256 reqId) external onlyRole(BOT) nonReentrant {
    require(!rejectAcknowledged[reqId], "reqId already acknowledged");

    (, address reqUser, uint256 lockedAssetAmount, uint256 shareAmount, , uint8 status) = IXAUEFundToken(xaueFundToken)
      .redemptions(reqId);
    require(reqUser == address(this), "not our reqId");
    require(status == REDEMPTION_STATUS_REJECTED, "not rejected");

    uint256 actualShares = IERC20(xaueFundToken).balanceOf(address(this));
    require(actualShares >= expectedShareBalance + shareAmount, "share balance below expected");

    rejectAcknowledged[reqId] = true;

    // Re-credit rejected shares as principal at request-time NAV. Any NAV delta (active slice
    // since last sync + the in-flight delta on these returned shares) surfaces as a normal
    // `getVault - lastVault` delta on the next `_updateVaultAssets` and is handled by the
    // standard fee + cap + totalSupply-zero path. We don't sync here — ack is a pure
    // accounting bump.
    expectedShareBalance += shareAmount;
    lastVaultTotalAssets += lockedAssetAmount;

    emit RedemptionRejectAcknowledged(reqId, shareAmount);
  }

  /* INTERNAL */

  /**
   * @dev Reconcile XAUE NAV movement against staking-side accounting.
   *      - NAV up (profit): charge feeRate% to `fee`, push remainder to staking as interest.
   *      - NAV down: impossible by construction -- CoboFundOracle NAV is monotonically non-decreasing
   *        (APR >= 0; every updateRate ratchets baseNetValue up via getLatestPrice). A decrease
   *        signals an oracle anomaly, not a real loss, so the sync fails closed instead of
   *        socialising a phantom loss onto holders. (Bailsec 03/04/06/28/29 -- loss path removed.)
   *
   *      Per-update absolute delta is capped at `maxDeltaBps` of `lastVaultTotalAssets` (default 10%,
   *      MANAGER-tunable up to MAX_DELTA_BPS_CAP). Defends against oracle anomalies; if exceeded,
   *      the call reverts and MANAGER must investigate before any further state changes proceed.
   */
  function _updateVaultAssets() private {
    // Hard invariant: actual XAUE shares must back at least the tracked `expectedShareBalance`.
    // Excess actual (dust, not-yet-acked rejects) is harmless and ignored by the NAV math; a
    // DEFICIT (actual < expected, e.g., after MANAGER emergencyWithdraw on xaueFundToken without
    // a matching expectedShareBalance adjustment) means we'd otherwise compute interest on shares
    // we don't actually hold — revert and force MANAGER to reconcile via upgrade.
    require(IERC20(xaueFundToken).balanceOf(address(this)) >= expectedShareBalance, "share balance below expected");

    uint256 newVaultTotalAssets = getVaultTotalAssets();
    // XAUE NAV cannot decrease (see @dev). A drop is an oracle anomaly -- fail closed rather than
    // propagate a loss the product cannot incur.
    require(newVaultTotalAssets >= lastVaultTotalAssets, "vault value decreased");

    if (newVaultTotalAssets > lastVaultTotalAssets) {
      uint256 totalInterest = newVaultTotalAssets - lastVaultTotalAssets;
      (uint256 interestFee, uint256 netInterest) = _pushInterest(totalInterest, lastVaultTotalAssets);
      emit UpdateVaultAssets(newVaultTotalAssets, totalInterest, interestFee, netInterest);
    }
    lastVaultTotalAssets = newVaultTotalAssets;
  }

  /**
   * @dev Charge feeRate% on `gain` to `fee`, push net to staking via increaseTotalAssets. Reverts
   *      if `gain / baseValue > maxDeltaBps / 10000` (oracle anomaly guard), except when
   *      `baseValue == 0`, where the ratio cap is undefined and is skipped (see inline note).
   *
   *      Special-case when there are no slisXAUE holders (`totalSupply == 0`): the entire `gain` is
   *      attributed to `fee`. Protocol is the only stakeholder during such windows, so no user
   *      portion exists. This also avoids leaving an "orphan" value buried in adapter principal
   *      that nobody has a claim on.
   *
   *      Called only by `_updateVaultAssets`. `acknowledgeReject` defers any in-flight gain to
   *      the next sync rather than pushing here directly.
   */
  function _pushInterest(uint256 gain, uint256 baseValue) private returns (uint256 gainFee, uint256 netGain) {
    // baseValue == 0 means the prior tracked value floored to 0 while expectedShareBalance is still a
    // sub-1-XAUT dust residual (after a full fee-redemption or a near-full staker exit). The per-update
    // ratio cap is undefined against a zero base and would make the next 0 -> positive transition revert
    // forever, bricking every sync-first entry point. Skip it in that degenerate case -- the gain is
    // dust-bounded, not an oracle anomaly. (Bailsec 05/10)
    if (baseValue > 0) {
      require(gain * 10000 <= baseValue * maxDeltaBps, "delta exceeds max");
    }

    if (IERC20(slisXAUE).totalSupply() == 0) {
      fee += gain;
      return (gain, 0);
    }

    gainFee = gain.mulDiv(feeRate, PRECISION);
    fee += gainFee;
    netGain = gain - gainFee;
    if (netGain > 0) {
      IXAUTStaking(staking).increaseTotalAssets(netGain);
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
