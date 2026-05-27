// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ISlisXAUE } from "./interface/ISlisXAUE.sol";
import { IXAUEAdapter } from "./interface/IXAUEAdapter.sol";

/**
 * @title XAUTStaking
 * @notice User-facing business logic for slisXAUE: deposit XAUT → mint slisXAUE shares;
 *         requestWithdraw burns shares immediately and queues a batch withdrawal; claim transfers
 *         XAUT back after the batch is finalized.
 *
 *         Rate management: convertRate is updated only via Adapter.increaseTotalAssets (interest push) and is
 *         expressed via convertToShares/convertToAssets math (no separate rate state variable).
 *
 *         Decimal handling: XAUT is 6-dec, slisXAUE is 18-dec. Internal `userTotalAssetsScaled` is kept
 *         in 18-dec scale (= asset wei × SCALE_RATIO) so conversion math reads cleanly.
 */
contract XAUTStaking is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;
  using Math for uint256;

  /* STRUCTS */
  struct WithdrawalRequest {
    uint256 batchId;
    uint256 withdrawTime;
    uint256 amount; // asset (XAUT) amount, 6-dec
  }

  /* VARIABLES */
  /// @notice The asset token (XAUT, 6-dec)
  address public asset;
  /// @notice The share token (slisXAUE, 18-dec)
  ISlisXAUE public slisXAUE;
  /// @notice The adapter contract that bridges to XAUE Protocol
  address public adapter;
  /// @notice Total user-owned XAUT value, in 18-dec scale (= asset wei × SCALE_RATIO)
  uint256 public userTotalAssetsScaled;
  /// @notice batchId => total XAUT amount requested in that batch
  mapping(uint256 => uint256) public totalWithdrawAmountInBatch;
  /// @notice user => withdrawal requests
  mapping(address => WithdrawalRequest[]) private userWithdrawalRequests;
  /// @notice XAUT received from adapter, not yet allocated to batches
  uint256 public withdrawQuota;
  /// @notice block.timestamp / 1 days at the last batch increment
  uint256 public lastDay;
  /// @notice Current active batch id (accepts new requests)
  uint256 public currentBatchId;
  /// @notice Last batch id fully funded by adapter (≤ currentBatchId)
  uint256 public confirmedBatchId;
  /// @notice Minimum deposit, in asset (XAUT, 6-dec) units
  uint256 public minDeposit;
  /// @notice Minimum withdraw request, in asset (XAUT, 6-dec) units
  uint256 public minWithdraw;
  /// @notice Maximum total shares (18-dec). Risk control; users do not see this number.
  uint256 public mintCap;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  uint256 public constant SCALE_RATIO = 1e12; // 1e18 / 1e6 (slisXAUE / XAUT)

  /* EVENTS */
  event Deposit(address indexed user, uint256 amount, uint256 shares);
  event RequestWithdraw(
    address indexed owner,
    address indexed receiver,
    uint256 batchId,
    uint256 shares,
    uint256 amount
  );
  event FinishWithdraw(uint256 indexed batchId, uint256 amount);
  event ClaimWithdrawal(address indexed user, uint256 idx, uint256 amount);
  event IncreaseTotalAssets(uint256 amount);
  event DecreaseTotalAssets(uint256 amount);
  /// @notice Emitted when adapter pushed interest/loss while no slisXAUE holders existed. Value stays
  ///         as adapter-side principal buffer; off-chain monitor should pick this up for reconciliation.
  event IncreaseTotalAssetsSkipped(uint256 amount);
  event DecreaseTotalAssetsSkipped(uint256 amount);
  event MintCapUpdated(uint256 oldCap, uint256 newCap);
  event SetMinDeposit(uint256 minDeposit);
  event SetMinWithdraw(uint256 minWithdraw);
  event SetAsset(address asset);
  event SetSlisXAUE(address slisXAUE);
  event SetAdapter(address adapter);
  event EmergencyWithdraw(address token, uint256 amount);

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  /**
   * @dev Initialize the contract
   * @param _admin DEFAULT_ADMIN_ROLE (TimeLock multisig)
   * @param _manager MANAGER role: params
   * @param _pauser PAUSER role
   * @param _asset XAUT address (6-dec ERC20)
   * @param _slisXAUE slisXAUE address (18-dec share token; XAUTStaking must be granted MINTER on it)
   * @param _adapter XAUEAdapter address
   * @param _mintCap Initial mint cap (in 18-dec slisXAUE shares)
   */
  function initialize(
    address _admin,
    address _manager,
    address _pauser,
    address _asset,
    address _slisXAUE,
    address _adapter,
    uint256 _mintCap
  ) public initializer {
    require(_admin != address(0), "admin is zero");
    require(_manager != address(0), "manager is zero");
    require(_pauser != address(0), "pauser is zero");
    require(_asset != address(0), "asset is zero");
    require(_slisXAUE != address(0), "slisXAUE is zero");
    require(_adapter != address(0), "adapter is zero");

    __AccessControl_init();
    __Pausable_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);

    asset = _asset;
    slisXAUE = ISlisXAUE(_slisXAUE);
    adapter = _adapter;
    mintCap = _mintCap;

    emit SetAsset(_asset);
    emit SetSlisXAUE(_slisXAUE);
    emit SetAdapter(_adapter);
    emit MintCapUpdated(0, _mintCap);
  }

  /* USER ENTRY POINTS */

  /**
   * @notice Deposit XAUT to receive slisXAUE shares.
   * @param amount XAUT amount (6-dec); pass 0 to specify shares instead
   * @param shares Desired share amount (18-dec); pass 0 to specify amount instead
   * @param receiver The address to receive the shares
   */
  function deposit(uint256 amount, uint256 shares, address receiver) external whenNotPaused nonReentrant {
    require(amount > 0 || shares > 0, "amount and shares both zero");
    require(receiver != address(0), "receiver is zero");

    // Sync NAV-based interest/loss before pricing — front-run mitigation (audit B/H-01).
    IXAUEAdapter(adapter).updateVaultAssets();

    if (amount > 0) {
      shares = convertToShares(amount);
    } else {
      amount = convertToAssets(shares);
    }

    require(shares > 0, "shares is zero");
    require(amount > 0, "amount is zero");
    require(amount >= minDeposit, "below min deposit");
    require(slisXAUE.totalSupply() + shares <= mintCap, "exceeds mint cap");

    slisXAUE.mint(receiver, shares);
    userTotalAssetsScaled += amount * SCALE_RATIO;
    IERC20(asset).safeTransferFrom(msg.sender, adapter, amount);

    emit Deposit(receiver, amount, shares);
  }

  /**
   * @notice Burn slisXAUE immediately and queue a withdrawal request for XAUT. shares are burned at
   *         this call (Option A: "burn at request"). Cannot be cancelled.
   * @param amount XAUT amount (6-dec); pass 0 to specify shares instead
   * @param shares Share amount (18-dec); pass 0 to specify amount instead
   * @param receiver The address recorded as the request owner (target of future claim)
   */
  function requestWithdraw(uint256 amount, uint256 shares, address receiver) external whenNotPaused nonReentrant {
    require(amount > 0 || shares > 0, "amount and shares both zero");
    require(receiver != address(0), "receiver is zero");

    // Sync NAV-based interest/loss before pricing — symmetric defense with deposit (audit B/H-01).
    IXAUEAdapter(adapter).updateVaultAssets();

    if (amount > 0) {
      shares = convertToShares(amount);
    } else {
      amount = convertToAssets(shares);
    }
    // Round shares up so the burned shares always cover the locked amount
    if (convertToAssets(shares) < amount) {
      shares += 1;
    }

    require(shares > 0, "shares is zero");
    require(amount > 0, "amount is zero");
    require(amount >= minWithdraw, "below min withdraw");
    require(slisXAUE.balanceOf(msg.sender) >= shares, "insufficient shares");

    slisXAUE.burn(msg.sender, shares);

    // Advance batch on new day or when previous batch is already confirmed
    uint256 day = block.timestamp / 1 days;
    if (day > lastDay) {
      lastDay = day;
      ++currentBatchId;
    } else if (currentBatchId == confirmedBatchId) {
      ++currentBatchId;
    }

    userWithdrawalRequests[receiver].push(
      WithdrawalRequest({ batchId: currentBatchId, amount: amount, withdrawTime: block.timestamp })
    );
    totalWithdrawAmountInBatch[currentBatchId] += amount;
    userTotalAssetsScaled -= amount * SCALE_RATIO;

    emit RequestWithdraw(msg.sender, receiver, currentBatchId, shares, amount);
  }

  /**
   * @notice Claim an already-finalized withdrawal request belonging to `msg.sender`. Shares were
   *         burned at request time, so this only transfers XAUT out. Self-only -- third parties
   *         cannot trigger another user's claim.
   * @param idx Index into the caller's request array (swap-and-pop after claim)
   */
  function claimWithdraw(uint256 idx) external whenNotPaused nonReentrant {
    WithdrawalRequest[] storage userRequests = userWithdrawalRequests[msg.sender];
    require(idx < userRequests.length, "invalid index");
    WithdrawalRequest memory req = userRequests[idx];
    require(req.batchId <= confirmedBatchId, "not claimable yet");

    // swap-and-pop
    userRequests[idx] = userRequests[userRequests.length - 1];
    userRequests.pop();

    IERC20(asset).safeTransfer(msg.sender, req.amount);
    emit ClaimWithdrawal(msg.sender, idx, req.amount);
  }

  /* ADAPTER CALLBACKS */

  /**
   * @notice Push net interest (XAUT-equivalent value) from Adapter. Updates convertRate immediately.
   * @dev    No-op when `slisXAUE.totalSupply() == 0`. Crediting interest while there are no holders
   *         would leave `userTotalAssetsScaled > 0` with `totalSupply == 0`, which would mis-price the
   *         next deposit's shares (next user gets fewer slisXAUE than 1:1 → unintended windfall, since
   *         their shares end up entitled to a share of the orphan value). The NAV-driven gain stays
   *         as a buffer on the adapter side (lastVaultTotalAssets grows without a matching staking
   *         credit); MANAGER can later move it via `emergencyWithdraw` if needed.
   */
  function increaseTotalAssets(uint256 amount) external {
    require(msg.sender == adapter, "only adapter");
    if (slisXAUE.totalSupply() == 0) {
      emit IncreaseTotalAssetsSkipped(amount);
      return;
    }
    userTotalAssetsScaled += amount * SCALE_RATIO;
    emit IncreaseTotalAssets(amount);
  }

  /**
   * @notice Push a NAV-drop loss from Adapter; reduces convertRate pro-rata (users bear the loss).
   *         Caps at current `userTotalAssetsScaled` to avoid underflow; any leftover is silently
   *         dropped — at that point adapter is over-reporting loss vs what users still own, which is
   *         only possible if all active stake has been withdrawn.
   * @dev    Also no-ops when `slisXAUE.totalSupply() == 0` (no holders to absorb the loss). Mirror
   *         of the increaseTotalAssets guard.
   */
  function decreaseTotalAssets(uint256 amount) external {
    require(msg.sender == adapter, "only adapter");
    if (slisXAUE.totalSupply() == 0) {
      emit DecreaseTotalAssetsSkipped(amount);
      return;
    }
    uint256 scaled = amount * SCALE_RATIO;
    if (scaled >= userTotalAssetsScaled) {
      scaled = userTotalAssetsScaled; // cap
    }
    userTotalAssetsScaled -= scaled;
    emit DecreaseTotalAssets(amount);
  }

  /**
   * @notice Adapter delivers XAUT back to cover finalized withdrawal batches (FIFO). amount=0 is allowed
   *         (BOT can tick batch state without transferring new funds).
   */
  function finishWithdraw(uint256 amount) external {
    require(msg.sender == adapter, "only adapter");

    if (amount > 0) {
      IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
      withdrawQuota += amount;
    }

    // FIFO confirm batches whose total is fully covered by withdrawQuota
    for (uint256 i = confirmedBatchId + 1; i <= currentBatchId; i++) {
      uint256 batchAmount = totalWithdrawAmountInBatch[i];
      if (batchAmount > withdrawQuota) break;
      confirmedBatchId = i;
      withdrawQuota -= batchAmount;
      emit FinishWithdraw(i, batchAmount);
    }
  }

  /* VIEW */

  /// @notice Convert XAUT amount (6-dec) to slisXAUE share amount (18-dec)
  function convertToShares(uint256 assets) public view returns (uint256) {
    // shares = assets × SCALE_RATIO × (totalSupply + 1) / (userTotalAssetsScaled + 1)
    // The +1 on each side prevents division-by-zero on the first deposit and mitigates the
    // first-deposit / donation attack (virtual shares / virtual assets approach).
    return (assets * SCALE_RATIO).mulDiv(slisXAUE.totalSupply() + 1, userTotalAssetsScaled + 1);
  }

  /// @notice Convert slisXAUE share amount (18-dec) to XAUT amount (6-dec)
  function convertToAssets(uint256 shares) public view returns (uint256) {
    return shares.mulDiv(userTotalAssetsScaled + 1, (slisXAUE.totalSupply() + 1) * SCALE_RATIO);
  }

  /// @notice Total asset value backing all shares, in XAUT 6-dec units. Equivalent to userTotalAssetsScaled / SCALE_RATIO.
  function totalAssets() public view returns (uint256) {
    return userTotalAssetsScaled / SCALE_RATIO;
  }

  /// @notice 1 slisXAUE (1e18 wei) is worth pricePerShare() XAUT wei (6-dec). Convenience view.
  function pricePerShare() external view returns (uint256) {
    return convertToAssets(1e18);
  }

  /// @notice Get the full withdrawal request list for `user`
  function getUserWithdrawalRequests(address user) external view returns (WithdrawalRequest[] memory) {
    return userWithdrawalRequests[user];
  }

  /// @notice 18 decimals fixed (matches slisXAUE)
  function decimals() external pure returns (uint8) {
    return 18;
  }

  /* ADMIN */

  function setMintCap(uint256 _mintCap) external onlyRole(MANAGER) {
    require(mintCap != _mintCap, "same mintCap");
    emit MintCapUpdated(mintCap, _mintCap);
    mintCap = _mintCap;
  }

  function setMinDeposit(uint256 _minDeposit) external onlyRole(MANAGER) {
    require(minDeposit != _minDeposit, "same minDeposit");
    minDeposit = _minDeposit;
    emit SetMinDeposit(_minDeposit);
  }

  function setMinWithdraw(uint256 _minWithdraw) external onlyRole(MANAGER) {
    require(minWithdraw != _minWithdraw, "same minWithdraw");
    minWithdraw = _minWithdraw;
    emit SetMinWithdraw(_minWithdraw);
  }

  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    require(amount > 0, "amount is zero");
    IERC20(token).safeTransfer(msg.sender, amount);
    emit EmergencyWithdraw(token, amount);
  }

  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
