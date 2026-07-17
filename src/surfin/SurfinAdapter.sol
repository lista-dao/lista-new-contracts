// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ICreditFundPool } from "./interface/ICreditFundPool.sol";
import { IOTCManager } from "./interface/IOTCManager.sol";
import { IAsyncVault } from "./interface/IAsyncVault.sol";
import { IInterestDistributor } from "./interface/IInterestDistributor.sol";

/**
 * @title SurfinAdapter
 * @notice Shared adapter for the Surfin Credit Fund, following the design of
 *         lista-new-contracts/src/rwa/RWAAdapter.sol.
 *
 * Both the flex and locked pools forward user deposits straight to this adapter,
 * so all fund logic lives here:
 *  - deploy idle funds to Surfin (off-chain) through the OTCManager, not split by
 *    product — one combined transfer;
 *  - keep a per-product buffer (target / hard floor) computed on the fly from each
 *    pool's principal, no physical split;
 *  - earmark matured locked principal into a settlement reserve that can never be
 *    deployed or used for buffer;
 *  - repay the pools' batch queues and book interest;
 *  - reserve the IAsyncVault channel for a future liquid yield source (PSM / Venus)
 *    so idle buffer can earn yield while staying instantly redeemable.
 */
contract SurfinAdapter is AccessControlEnumerableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
  using SafeERC20 for IERC20;
  using Math for uint256;

  /* VARIABLES */
  // flex (demand) pool
  address public flexPool;
  // locked (term) pool
  address public lockedPool;
  // OTC manager (gateway to Surfin)
  address public otcManager;
  // interest distributor (cumulative Merkle interest payouts)
  address public interestDistributor;

  // matured locked principal earmark; never deployable/usable for buffer
  uint256 public settlementReserve;
  // accrued Lista profit fee earmark; withdrawable by manager only
  uint256 public accruedFee;
  // book value currently deployed to Surfin
  uint256 public deployedToSurfin;

  // buffer target / hard floor rates, 1e18 (e.g. 0.15e18 = 15%)
  uint256 public flexBufferRate;
  uint256 public flexFloorRate;
  uint256 public lockedBufferRate;
  uint256 public lockedFloorRate;

  // max amount deployable to Surfin per weekly cycle
  uint256 public maxDeployPerWeek;
  // last cycle (week) a deploy happened
  uint256 public deployCycle;
  // last cycle (week) a recall/settlement happened; blocks deploy in the same cycle
  uint256 public recallCycle;

  // profit fee receiver and rate (1e18); rate is informational for off-chain sizing
  address public feeReceiver;
  uint256 public feeRate;

  // PSM / Venus reservation (liquid yield source), 0 until enabled
  address public vault;
  address public shareToken;

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
  event AllocateToSettlement(uint256 amount);
  event ReleaseSettlement(uint256 amount);
  event FinishFlexWithdraw(uint256 amount);
  event FinishLockedWithdraw(uint256 amount);
  event FundInterest(uint256 amount);
  event BookFee(uint256 amount);
  event ClaimFee(address receiver, uint256 amount);
  event RequestRecall(uint256 amount);
  event RepayFromSurfin(uint256 amount);
  event SetBufferRates(uint256 flexBuffer, uint256 flexFloor, uint256 lockedBuffer, uint256 lockedFloor);
  event SetMaxDeployPerWeek(uint256 maxDeployPerWeek);
  event SetOTCManager(address otcManager);
  event SetInterestDistributor(address interestDistributor);
  event SetFeeReceiver(address feeReceiver);
  event SetFeeRate(uint256 feeRate);
  event SetVault(address vault, address shareToken);
  event EmergencyWithdraw(address token, uint256 amount);
  // PSM channel (reserved)
  event RequestDepositToVault(uint256 amount);
  event DepositToVault(uint256 shares);
  event RequestWithdrawFromVault(uint256 shares);
  event WithdrawFromVault(uint256 shares);

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
    address _otcManager
  ) external initializer {
    require(_admin != address(0), "admin is zero address");
    require(_manager != address(0), "manager is zero address");
    require(_pauser != address(0), "pauser is zero address");
    require(_bot != address(0), "bot is zero address");
    require(_flexPool != address(0), "flexPool is zero address");
    require(_lockedPool != address(0), "lockedPool is zero address");
    require(_otcManager != address(0), "otcManager is zero address");

    __AccessControlEnumerable_init();
    __Pausable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);
    _grantRole(BOT, _bot);

    flexPool = _flexPool;
    lockedPool = _lockedPool;
    otcManager = _otcManager;

    // defaults: flex 15%/3%, locked 5%/1.5%
    flexBufferRate = 15 * 1e16;
    flexFloorRate = 3 * 1e16;
    lockedBufferRate = 5 * 1e16;
    lockedFloorRate = 15 * 1e15;
  }

  /* DEPLOY TO SURFIN */
  /**
   * @dev deploy idle funds to Surfin through the OTC manager. Not split by product.
   *      Blocked while paused, capped by the deployable amount, the weekly cap, and
   *      the net-flow rule (no deploy in a cycle that already recalled).
   * @param amount the amount of asset to deploy
   */
  function deployToSurfin(uint256 amount) external onlyRole(BOT) whenNotPaused {
    require(amount > 0, "amount is zero");
    require(amount <= maxDeployToSurfin(), "exceeds deployable");
    require(maxDeployPerWeek == 0 || amount <= maxDeployPerWeek, "exceeds weekly cap");

    uint256 cycle = block.timestamp / 1 weeks;
    require(recallCycle != cycle, "recalled this cycle");
    deployCycle = cycle;

    deployedToSurfin += amount;

    IERC20(asset).safeIncreaseAllowance(otcManager, amount);
    IOTCManager(otcManager).swapToken(asset, amount);

    emit DeployToSurfin(amount);
  }

  /**
   * @dev request a recall from Surfin (T-30 funding request). Off-chain settled;
   *      marks the cycle so no deploy happens in the same cycle.
   * @param amount the requested recall amount
   */
  function requestRecall(uint256 amount) external onlyRole(BOT) {
    recallCycle = block.timestamp / 1 weeks;
    emit RequestRecall(amount);
  }

  /**
   * @dev account for funds returned from Surfin. The BOT first pulls the funds back
   *      to this adapter via OTCManager.transferToAdapter, then calls this to reduce
   *      the deployed book value.
   * @param amount the principal amount returned
   */
  function repayFromSurfin(uint256 amount) external onlyRole(BOT) {
    require(amount > 0, "amount is zero");
    recallCycle = block.timestamp / 1 weeks;
    deployedToSurfin = deployedToSurfin > amount ? deployedToSurfin - amount : 0;
    emit RepayFromSurfin(amount);
  }

  /* SETTLEMENT RESERVE (matured locked principal) */
  /**
   * @dev earmark matured locked principal into the settlement reserve (locked, not
   *      deployable). Funds must already be on this adapter.
   * @param amount the matured principal to reserve
   */
  function allocateToSettlement(uint256 amount) external onlyRole(BOT) {
    require(amount > 0, "amount is zero");
    require(_availableToEarmark() >= amount, "insufficient idle");
    settlementReserve += amount;
    emit AllocateToSettlement(amount);
  }

  /**
   * @dev release settlement reserve to cover matured locked withdrawals.
   * @param amount the amount to release into the locked pool's queue
   */
  function releaseSettlement(uint256 amount) external onlyRole(BOT) {
    require(amount > 0 && amount <= settlementReserve, "invalid amount");
    settlementReserve -= amount;
    IERC20(asset).safeIncreaseAllowance(lockedPool, amount);
    ICreditFundPool(lockedPool).finishWithdraw(amount);
    emit ReleaseSettlement(amount);
  }

  /* REPAY POOL QUEUES */
  /**
   * @dev repay the flex pool's batch queue from idle funds. `amount` may be 0 to
   *      only advance batches.
   */
  function finishFlexWithdraw(uint256 amount) external onlyRole(BOT) {
    if (amount > 0) {
      IERC20(asset).safeIncreaseAllowance(flexPool, amount);
    }
    ICreditFundPool(flexPool).finishWithdraw(amount);
    emit FinishFlexWithdraw(amount);
  }

  /**
   * @dev repay the locked pool's batch queue (early-redeem pending) from idle funds.
   *      Matured principal should instead be covered via releaseSettlement.
   */
  function finishLockedWithdraw(uint256 amount) external onlyRole(BOT) {
    if (amount > 0) {
      IERC20(asset).safeIncreaseAllowance(lockedPool, amount);
    }
    ICreditFundPool(lockedPool).finishWithdraw(amount);
    emit FinishLockedWithdraw(amount);
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
    require(_availableToEarmark() >= amount, "insufficient idle");
    IERC20(asset).safeIncreaseAllowance(interestDistributor, amount);
    IInterestDistributor(interestDistributor).notifyReward(asset, amount);
    emit FundInterest(amount);
  }

  /* PROFIT FEE (Lista share) */
  /**
   * @dev earmark accrued profit fee (Lista's share). Funds must already be idle.
   */
  function bookFee(uint256 amount) external onlyRole(BOT) {
    require(amount > 0, "amount is zero");
    require(_availableToEarmark() >= amount, "insufficient idle");
    accruedFee += amount;
    emit BookFee(amount);
  }

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
   * @dev total instantly-available liquidity held by the adapter, including any
   *      liquid yield source (PSM) when enabled.
   */
  function idleBalance() public view returns (uint256) {
    uint256 bal = IERC20(asset).balanceOf(address(this));
    bal += getVaultTotalAssets(); // 0 until PSM is enabled
    return bal;
  }

  /**
   * @dev freely usable idle funds after excluding the settlement reserve and fee.
   */
  function freeIdle() public view returns (uint256) {
    uint256 bal = idleBalance();
    uint256 locked = settlementReserve + accruedFee;
    return bal > locked ? bal - locked : 0;
  }

  function flexBufferTarget() public view returns (uint256) {
    return (ICreditFundPool(flexPool).totalPrincipal() * flexBufferRate) / PRECISION;
  }

  function lockedBufferTarget() public view returns (uint256) {
    return (ICreditFundPool(lockedPool).totalPrincipal() * lockedBufferRate) / PRECISION;
  }

  function flexFloor() public view returns (uint256) {
    return (ICreditFundPool(flexPool).totalPrincipal() * flexFloorRate) / PRECISION;
  }

  function lockedFloor() public view returns (uint256) {
    return (ICreditFundPool(lockedPool).totalPrincipal() * lockedFloorRate) / PRECISION;
  }

  /**
   * @dev max amount that can be deployed to Surfin: free idle minus both pools'
   *      pending withdrawals and both buffer targets.
   */
  function maxDeployToSurfin() public view returns (uint256) {
    uint256 free = freeIdle();
    uint256 reserved = ICreditFundPool(flexPool).totalPendingWithdraw() +
      ICreditFundPool(lockedPool).totalPendingWithdraw() +
      flexBufferTarget() +
      lockedBufferTarget();
    return free > reserved ? free - reserved : 0;
  }

  /**
   * @dev informational: instantly withdrawable amount that can be paid to users,
   *      down to the hard floors (buffer can be consumed to the floor for payouts).
   */
  function instantWithdrawable() external view returns (uint256) {
    uint256 free = freeIdle();
    uint256 reserved = ICreditFundPool(flexPool).totalPendingWithdraw() +
      ICreditFundPool(lockedPool).totalPendingWithdraw() +
      flexFloor() +
      lockedFloor();
    return free > reserved ? free - reserved : 0;
  }

  /**
   * @dev total assets managed by the liquid yield source (PSM). 0 until enabled.
   */
  function getVaultTotalAssets() public view returns (uint256) {
    if (vault == address(0) || shareToken == address(0)) {
      return 0;
    }
    uint256 shares = IERC20(shareToken).balanceOf(address(this));
    return IAsyncVault(vault).convertToAssets(shares);
  }

  /* PSM / VENUS CHANNEL (reserved, mirrors RWAAdapter) */
  /**
   * @dev request deposit of idle funds into the liquid yield vault (PSM).
   */
  function requestDepositToVault(uint256 amount) external onlyRole(BOT) whenNotPaused {
    require(vault != address(0), "vault not set");
    require(amount > 0, "amount is zero");
    IERC20(asset).safeIncreaseAllowance(vault, amount);
    IAsyncVault(vault).requestDeposit(amount, address(this), address(this));
    emit RequestDepositToVault(amount);
  }

  /**
   * @dev finish a pending deposit and mint vault shares.
   */
  function depositToVault() external onlyRole(BOT) whenNotPaused {
    require(vault != address(0), "vault not set");
    uint256 maxMint = IAsyncVault(vault).maxMint(address(this));
    require(maxMint > 0, "maxMint is zero");
    IAsyncVault(vault).mint(maxMint, address(this));
    emit DepositToVault(maxMint);
  }

  /**
   * @dev request redeem of vault shares back to idle asset.
   */
  function requestWithdrawFromVault(uint256 shares) external onlyRole(BOT) {
    require(vault != address(0), "vault not set");
    require(shares > 0, "shares is zero");
    IERC20(shareToken).safeIncreaseAllowance(vault, shares);
    IAsyncVault(vault).requestRedeem(shares, address(this), address(this));
    emit RequestWithdrawFromVault(shares);
  }

  /**
   * @dev finish a pending redeem, pulling asset back to the adapter.
   */
  function withdrawFromVault() external onlyRole(BOT) {
    require(vault != address(0), "vault not set");
    uint256 maxRedeem = IAsyncVault(vault).maxRedeem(address(this));
    require(maxRedeem > 0, "maxRedeem is zero");
    IAsyncVault(vault).redeem(maxRedeem, address(this), address(this));
    emit WithdrawFromVault(maxRedeem);
  }

  /* MANAGER FUNCTIONS */
  /// @dev emergency stop for outbound flows (deploy to Surfin, deposits to the PSM vault)
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  /// @dev lift the emergency stop
  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function setBufferRates(
    uint256 _flexBuffer,
    uint256 _flexFloor,
    uint256 _lockedBuffer,
    uint256 _lockedFloor
  ) external onlyRole(MANAGER) {
    require(_flexFloor <= _flexBuffer && _flexBuffer <= PRECISION, "invalid flex rates");
    require(_lockedFloor <= _lockedBuffer && _lockedBuffer <= PRECISION, "invalid locked rates");
    flexBufferRate = _flexBuffer;
    flexFloorRate = _flexFloor;
    lockedBufferRate = _lockedBuffer;
    lockedFloorRate = _lockedFloor;
    emit SetBufferRates(_flexBuffer, _flexFloor, _lockedBuffer, _lockedFloor);
  }

  function setMaxDeployPerWeek(uint256 _maxDeployPerWeek) external onlyRole(MANAGER) {
    maxDeployPerWeek = _maxDeployPerWeek;
    emit SetMaxDeployPerWeek(_maxDeployPerWeek);
  }

  function setOTCManager(address _otcManager) external onlyRole(MANAGER) {
    require(_otcManager != address(0), "otcManager is zero address");
    otcManager = _otcManager;
    emit SetOTCManager(_otcManager);
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
   * @dev set the liquid yield source (PSM / Venus). shareToken is the vault's share token.
   */
  function setVault(address _vault, address _shareToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
    vault = _vault;
    shareToken = _shareToken;
    emit SetVault(_vault, _shareToken);
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
   * @dev on-adapter asset balance available to earmark (excludes existing earmarks).
   */
  function _availableToEarmark() internal view returns (uint256) {
    uint256 bal = IERC20(asset).balanceOf(address(this));
    uint256 locked = settlementReserve + accruedFee;
    return bal > locked ? bal - locked : 0;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  // reserve storage for future upgrades
  uint256[44] private __gap;
}
