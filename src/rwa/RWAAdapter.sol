// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAsyncVault } from "./interface/IAsyncVault.sol";
import { IRWAEarnPool } from "./interface/IRWAEarnPool.sol";
import { IOTCManager } from "./interface/IOTCManager.sol";

contract RWAAdapter is AccessControlEnumerableUpgradeable, UUPSUpgradeable {
  using SafeERC20 for IERC20;
  using Math for uint256;

  /* VARIABLES */
  // otc manager address
  address public otcManager;
  // earn pool address
  address public earnPool;
  // vault address
  address public vault;
  // vault share token address
  address public shareToken;
  // fee receiver address
  address public feeReceiver;
  // loss rate when swap asset to vault asset, 18 decimals
  uint256 public toVaultAssetLossRate;
  // loss rate when swap vault asset to asset, 18 decimals
  uint256 public toAssetLossRate;
  // fee rate, 18 decimals
  uint256 public feeRate;
  // accumulated fee, asset is vault asset
  uint256 public fee;
  // last total assets in vault
  uint256 public lastVaultTotalAssets;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  uint256 public constant PRECISION = 1e18;
  uint256 public constant MAX_FEE_RATE = 3 * 1e17; // 30%

  /* IMMUTABLE */
  address public immutable asset;
  address public immutable vaultAsset;

  /* EVENTS */
  event RequestDepositToVault(uint256 amount);
  event RequestWithdrawFromVault(uint256 shares, uint256 expectAmount);
  event MintVaultShares(uint256 shares);
  event WithdrawFromVault(uint256 shares, uint256 totalAmount, uint256 feeAmount);
  event EmergencyWithdraw(address token, uint256 amount);
  event SetFeeReceiver(address feeReceiver);
  event SetFeeRate(uint256 feeRate);
  event SetToVaultAssetLossRate(uint256 toVaultAssetLossRate);
  event SetToAssetLossRate(uint256 toAssetLossRate);

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param _asset The address of the asset token.
  /// @param _vaultAsset The address of the vault asset token.
  constructor(address _asset, address _vaultAsset) {
    require(_asset != address(0), "asset is zero address");
    require(_vaultAsset != address(0), "vaultAsset is zero address");
    _disableInitializers();
    asset = _asset;
    vaultAsset = _vaultAsset;
  }

  /* INITIALIZER */
  /**
   * @dev initializes the contract.
   * @param _admin The address of the admin.
   * @param _manager The address of the manager.
   * @param _bot The address of the bot.
   * @param _earnPool The address of the earn pool.
   * @param _vault The address of the vault.
   * @param _shareToken The address of the vault share token.
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _earnPool,
    address _vault,
    address _shareToken
  ) public initializer {
    require(_admin != address(0), "Admin address cannot be zero");
    require(_manager != address(0), "Manager address cannot be zero");
    require(_bot != address(0), "Bot address cannot be zero");
    require(_earnPool != address(0), "EarnPool address cannot be zero");
    require(_vault != address(0), "Vault address cannot be zero");
    require(_shareToken != address(0), "ShareToken address cannot be zero");

    // initialize inherited contracts
    __AccessControlEnumerable_init();

    // setup roles
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(BOT, _bot);

    // setup variables
    earnPool = _earnPool;
    vault = _vault;
    shareToken = _shareToken;
  }

  /* EXTERNAL FUNCTIONS */
  /**
   * @dev request to deposit vault asset to vault
   * @param amountVaultAsset The amount of vault asset to deposit
   */
  function requestDepositToVault(uint256 amountVaultAsset) external onlyRole(BOT) {
    require(amountVaultAsset > 0, "Amount amountVaultAsset be greater than zero");
    _requestDepositToVault(amountVaultAsset);
  }

  /**
   * @dev finish deposit request and mint vault shares
   */
  function depositToVault() external onlyRole(BOT) {
    // get max mint amount from vault
    uint256 maxMint = IAsyncVault(vault).maxMint(address(this));
    // require max mint amount > 0
    require(maxMint > 0, "maxMint is zero");
    // update vault assets and charge fee
    _updateVaultAssets();

    // mint vault shares
    uint256 before = IERC20(shareToken).balanceOf(address(this));
    IAsyncVault(vault).mint(maxMint, address(this));
    require(IERC20(shareToken).balanceOf(address(this)) - before == maxMint, "mint shares failed");

    // update lastVaultTotalAssets
    lastVaultTotalAssets = getVaultTotalAssets();

    emit MintVaultShares(maxMint);
  }

  /**
   * @dev deposit rewards to earn pool
   * @param amountVaultAsset The amount of vault asset to deposit as rewards
   */
  function depositRewards(uint256 amountVaultAsset) external onlyRole(MANAGER) {
    require(amountVaultAsset > 0, "Amount must be greater than zero");
    require(IRWAEarnPool(earnPool).totalSupply() > 0, "Earn pool has no shares");

    // transfer vault asset from manager to this contract
    IERC20(vaultAsset).safeTransferFrom(msg.sender, address(this), amountVaultAsset);
    // request deposit to vault
    _requestDepositToVault(amountVaultAsset);

    // convert vault asset to asset
    uint256 amountAsset = VaultAssetToAsset(amountVaultAsset);
    // notify interest to earn pool
    IRWAEarnPool(earnPool).notifyInterest(amountAsset);
  }

  /**
   * @dev request to withdraw vault asset from vault
   * @param amountVaultAsset The amount of vault asset to withdraw
   */
  function requestWithdrawFromVault(uint256 amountVaultAsset) external onlyRole(BOT) {
    require(amountVaultAsset > 0, "Amount must be greater than zero");
    // update vault assets and charge fee
    _updateVaultAssets();

    // calculate shares to redeem
    uint256 redeemShares = IAsyncVault(vault).convertToShares(amountVaultAsset);
    // approve shares to vault
    IERC20(shareToken).safeIncreaseAllowance(vault, redeemShares);
    // request redeem from vault
    uint256 before = IERC20(shareToken).balanceOf(address(this));
    IAsyncVault(vault).requestRedeem(redeemShares, address(this), address(this));
    require(before - IERC20(shareToken).balanceOf(address(this)) == redeemShares, "request redeem failed");

    // update lastVaultTotalAssets
    lastVaultTotalAssets = getVaultTotalAssets();

    emit RequestWithdrawFromVault(redeemShares, amountVaultAsset);
  }

  /**
   * @dev finish withdraw request and redeem vault asset from vault
   * @param claimFee Whether to claim the accumulated fee
   */
  function withdrawFromVault(bool claimFee) external onlyRole(BOT) {
    // get max redeem amount from vault
    uint256 maxRedeem = IAsyncVault(vault).maxRedeem(address(this));
    // require max redeem amount > 0
    require(maxRedeem > 0, "maxRedeem is zero");

    // redeem from vault
    uint256 before = IERC20(vaultAsset).balanceOf(address(this));
    IAsyncVault(vault).redeem(maxRedeem, address(this), address(this));
    uint256 totalAmount = IERC20(vaultAsset).balanceOf(address(this)) - before;

    uint256 feeAmount;
    if (claimFee && fee > 0) {
      require(feeReceiver != address(0), "feeReceiver is zero");
      require(totalAmount >= fee, "totalAmount < fee");

      // transfer fee to feeReceiver
      IERC20(vaultAsset).safeTransfer(feeReceiver, fee);
      feeAmount = fee;
      fee = 0;
    }

    emit WithdrawFromVault(maxRedeem, totalAmount, feeAmount);
  }

  /**
   * @dev finish withdraw requests in earn pool
   * @param amountAsset The amount of asset to cover withdraw
   */
  function finishEarnPoolWithdraw(uint256 amountAsset) external onlyRole(BOT) {
    require(amountAsset > 0, "Amount must be greater than zero");
    IERC20(asset).safeIncreaseAllowance(earnPool, amountAsset);
    IRWAEarnPool(earnPool).finishWithdraw(amountAsset);
  }

  /**
   * @dev swap token to otc manager
   * @param token The address of the token to swap
   * @param amount The amount of the token to swap
   */
  function swapToken(address token, uint256 amount) external onlyRole(BOT) {
    require(token == asset || token == vaultAsset, "Invalid token");
    require(amount > 0, "Amount must be greater than zero");
    require(otcManager != address(0), "otcManager is zero address");
    IERC20(token).safeIncreaseAllowance(otcManager, amount);
    IOTCManager(otcManager).swapToken(token, amount);
  }

  /**
   * @dev update vault assets and charge fee
   */
  function updateVaultAssets() external onlyRole(BOT) {
    _updateVaultAssets();
  }

  /* MANAGER FUNCTIONS */
  /**
   * @dev set fee receiver address
   * @param _feeReceiver The address of the fee receiver
   */
  function setFeeReceiver(address _feeReceiver) external onlyRole(MANAGER) {
    require(_feeReceiver != address(0), "feeReceiver is zero");
    feeReceiver = _feeReceiver;
    emit SetFeeReceiver(_feeReceiver);
  }

  /**
   * @dev set fee rate
   * @param _feeRate The fee rate (18 decimals)
   */
  function setFeeRate(uint256 _feeRate) external onlyRole(MANAGER) {
    require(_feeRate <= MAX_FEE_RATE, "feeRate too high"); // max 30%
    feeRate = _feeRate;
    emit SetFeeRate(_feeRate);
  }

  /**
   * @dev set loss rate when swap asset to vault asset
   * @param _toVaultAssetLossRate The loss rate (18 decimals)
   */
  function setToVaultAssetLossRate(uint256 _toVaultAssetLossRate) external onlyRole(MANAGER) {
    require(_toVaultAssetLossRate <= PRECISION, "toVaultAssetLossRate too high");
    toVaultAssetLossRate = _toVaultAssetLossRate;
    emit SetToVaultAssetLossRate(_toVaultAssetLossRate);
  }

  /**
   * @dev set loss rate when swap vault asset to asset
   * @param _toAssetLossRate The loss rate (18 decimals)
   */
  function setToAssetLossRate(uint256 _toAssetLossRate) external onlyRole(MANAGER) {
    require(_toAssetLossRate <= PRECISION, "toAssetLossRate too high");
    toAssetLossRate = _toAssetLossRate;
    emit SetToAssetLossRate(_toAssetLossRate);
  }

  /**
   * @dev set otc manager address
   * @param _otcManager The address of the otc manager
   */
  function setOTCManager(address _otcManager) external onlyRole(MANAGER) {
    require(_otcManager != address(0), "otcManager is zero address");
    otcManager = _otcManager;
  }

  /**
   * @dev get total assets in vault
   * @return total assets in vault (in vault asset)
   */
  function getVaultTotalAssets() public view returns (uint256) {
    uint256 shareTokenShares = IERC20(shareToken).balanceOf(address(this));
    return IAsyncVault(vault).convertToAssets(shareTokenShares);
  }

  /**
   * @dev get conversion from asset to vault asset
   * @param amount The amount of asset to convert
   * @return converted amount in vault asset
   */
  function AssetToVaultAsset(uint256 amount) public view returns (uint256) {
    return amount - amount.mulDiv(toVaultAssetLossRate, PRECISION);
  }

  /**
   * @dev get conversion from vault asset to asset
   * @param amount The amount of vault asset to convert
   * @return converted amount in asset
   */
  function VaultAssetToAsset(uint256 amount) public view returns (uint256) {
    return amount - amount.mulDiv(toAssetLossRate, PRECISION);
  }

  /**
   * @dev allows manager to withdraw tokens for emergency
   * @param token ERC20 token address
   * @param amount token amount
   * @param receiver receiver address
   */
  function emergencyWithdraw(address token, uint256 amount, address receiver) external onlyRole(MANAGER) {
    require(amount > 0, "Amount must be greater than zero");
    require(receiver != address(0), "Receiver is zero address");
    IERC20(token).safeTransfer(receiver, amount);
    emit EmergencyWithdraw(token, amount);
  }

  /* INTERNAL FUNCTIONS */
  function _requestDepositToVault(uint256 amountVaultAsset) private {
    // approve amount to vault
    IERC20(vaultAsset).safeIncreaseAllowance(vault, amountVaultAsset);

    // request deposit to vault
    // check vault asset balance decreased
    uint256 before = IERC20(vaultAsset).balanceOf(address(this));
    IAsyncVault(vault).requestDeposit(amountVaultAsset, address(this), address(this));
    require(
      before - IERC20(vaultAsset).balanceOf(address(this)) == amountVaultAsset,
      "vault asset request deposit failed"
    );

    emit RequestDepositToVault(amountVaultAsset);
  }

  function _updateVaultAssets() private {
    uint256 newVaultTotalAssets = getVaultTotalAssets();
    if (newVaultTotalAssets <= lastVaultTotalAssets) {
      // no profit
      return;
    }
    uint256 totalInterest = newVaultTotalAssets - lastVaultTotalAssets;

    // charge fee, asset is vault asset
    uint256 interestFee = totalInterest.mulDiv(feeRate, PRECISION);
    fee += interestFee;

    // convert to asset
    uint256 interest = VaultAssetToAsset(totalInterest - interestFee);

    // notify interest to earn pool
    if (interest > 0) {
      IRWAEarnPool(earnPool).notifyInterest(interest);
    }
    // update lastVaultTotalAssets
    lastVaultTotalAssets = newVaultTotalAssets;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
