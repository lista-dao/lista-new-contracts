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
  // loss rate when swap USD1 to USDC, 18 decimals
  uint256 public toUSDCLossRate;
  // loss rate when swap USDC to USD1, 18 decimals
  uint256 public toUSD1LossRate;
  // fee rate, 18 decimals
  uint256 public feeRate;
  // accumulated fee, asset is USDC
  uint256 public fee;
  // last total assets in vault
  uint256 public lastVaultTotalAssets;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  uint256 public constant PRECISION = 1e18;

  /* IMMUTABLE */
  address public immutable USD1;
  address public immutable USDC;

  /* EVENTS */
  event RequestDepositToVault(uint256 amount);
  event RequestWithdrawFromVault(uint256 shares, uint256 expectAmount);
  event MintVaultShares(uint256 shares);
  event WithdrawFromVault(uint256 shares, uint256 totalAmount, uint256 feeAmount);
  event EmergencyWithdraw(address token, uint256 amount);

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  /// @param _USD1 The address of the USD1 token.
  /// @param _USDC The address of the USDC token.
  constructor(address _USD1, address _USDC) {
    require(_USD1 != address(0), "USD1 is zero address");
    require(_USDC != address(0), "USDC is zero address");
    _disableInitializers();
    USD1 = _USD1;
    USDC = _USDC;
  }

  /* INITIALIZER */
  /**
   * @dev initializes the contract.
   * @param _admin The address of the admin.
   * @param _manager The address of the manager.
   * @param _bot The address of the bot.
   * @param _earnPool The address of the earn pool.
   * @param _otcManager The address of the OTC manager.
   * @param _vault The address of the vault.
   * @param _shareToken The address of the vault share token.
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _earnPool,
    address _otcManager,
    address _vault,
    address _shareToken
  ) public initializer {
    require(_admin != address(0), "Admin address cannot be zero");
    require(_manager != address(0), "Manager address cannot be zero");
    require(_bot != address(0), "Bot address cannot be zero");
    require(_earnPool != address(0), "EarnPool address cannot be zero");
    require(_otcManager != address(0), "OTCManager address cannot be zero");
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
    otcManager = _otcManager;
    vault = _vault;
    shareToken = _shareToken;
  }

  /* EXTERNAL FUNCTIONS */
  /**
   * @dev request to deposit USDC to vault
   * @param amountUSDC The amount of USDC to deposit
   */
  function requestDepositToVault(uint256 amountUSDC) external onlyRole(BOT) {
    require(amountUSDC > 0, "Amount must be greater than zero");
    _requestDepositToVault(amountUSDC);
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
    IAsyncVault(vault).mint(maxMint, address(this));

    // update lastVaultTotalAssets
    lastVaultTotalAssets = getVaultTotalAssets();

    emit MintVaultShares(maxMint);
  }

  /**
   * @dev deposit rewards to earn pool
   * @param amountUSDC The amount of USDC to deposit as rewards
   */
  function depositRewards(uint256 amountUSDC) external onlyRole(MANAGER) {
    require(amountUSDC > 0, "Amount must be greater than zero");

    // transfer USDC from manager to this contract
    IERC20(USDC).safeTransferFrom(msg.sender, address(this), amountUSDC);
    // request deposit to vault
    _requestDepositToVault(amountUSDC);

    // convert USDC to USD1
    uint256 amountUSD1 = USDCToUSD1(amountUSDC);
    // notify interest to earn pool
    IRWAEarnPool(earnPool).notifyInterest(amountUSD1);
  }

  /**
   * @dev request to withdraw USDC from vault
   * @param amountUSDC The amount of USDC to withdraw
   */
  function requestWithdrawFromVault(uint256 amountUSDC) external onlyRole(BOT) {
    require(amountUSDC > 0, "Amount must be greater than zero");
    // update vault assets and charge fee
    _updateVaultAssets();

    // calculate shares to redeem
    uint256 redeemShares = IAsyncVault(vault).convertToShares(amountUSDC);
    // approve shares to vault
    IERC20(shareToken).approve(vault, redeemShares);
    // request redeem from vault
    IAsyncVault(vault).requestRedeem(redeemShares, address(this), address(this));

    // update lastVaultTotalAssets
    lastVaultTotalAssets = getVaultTotalAssets();

    emit RequestWithdrawFromVault(redeemShares, amountUSDC);
  }

  /**
   * @dev finish withdraw request and redeem USDC from vault
   * @param claimFee Whether to claim the accumulated fee
   */
  function withdrawFromVault(bool claimFee) external onlyRole(BOT) {
    // get max redeem amount from vault
    uint256 maxRedeem = IAsyncVault(vault).maxRedeem(address(this));
    // require max redeem amount > 0
    require(maxRedeem > 0, "maxRedeem is zero");

    // redeem from vault
    uint256 before = IERC20(USDC).balanceOf(address(this));
    IAsyncVault(vault).redeem(maxRedeem, address(this), address(this));
    uint256 totalAmount = IERC20(USDC).balanceOf(address(this)) - before;

    uint256 feeAmount;
    if (claimFee && fee > 0) {
      require(feeReceiver != address(0), "feeReceiver is zero");
      require(totalAmount >= fee, "totalAmount < fee");

      // transfer fee to feeReceiver
      IERC20(USDC).safeTransfer(feeReceiver, fee);
      feeAmount = fee;
      fee = 0;
    }

    emit WithdrawFromVault(maxRedeem, totalAmount, feeAmount);
  }

  /**
   * @dev finish withdraw requests in earn pool
   * @param amountUSD1 The amount of USD1 to cover withdraw
   */
  function finishEarnPoolWithdraw(uint256 amountUSD1) external onlyRole(BOT) {
    require(amountUSD1 > 0, "Amount must be greater than zero");
    IERC20(USD1).safeIncreaseAllowance(earnPool, amountUSD1);
    IRWAEarnPool(earnPool).finishWithdraw(amountUSD1);
  }

  /**
   * @dev swap token to otc manager
   * @param token The address of the token to swap
   * @param amount The amount of the token to swap
   */
  function swapToken(address token, uint256 amount) external onlyRole(BOT) {
    require(token == USD1 || token == USDC, "Invalid token");
    require(amount > 0, "Amount must be greater than zero");
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
  }

  /**
   * @dev set fee rate
   * @param _feeRate The fee rate (18 decimals)
   */
  function setFeeRate(uint256 _feeRate) external onlyRole(MANAGER) {
    require(_feeRate <= PRECISION, "feeRate too high"); // max 10%
    feeRate = _feeRate;
  }

  /**
   * @dev set loss rate when swap USD1 to USDC
   * @param _toUSDCLossRate The loss rate (18 decimals)
   */
  function setToUSDCLossRate(uint256 _toUSDCLossRate) external onlyRole(MANAGER) {
    require(_toUSDCLossRate <= PRECISION, "toUSDCLossRate too high");
    toUSDCLossRate = _toUSDCLossRate;
  }

  /**
   * @dev set loss rate when swap USDC to USD1
   * @param _toUSD1LossRate The loss rate (18 decimals)
   */
  function setToUSD1LossRate(uint256 _toUSD1LossRate) external onlyRole(MANAGER) {
    require(_toUSD1LossRate <= PRECISION, "toUSD1LossRate too high");
    toUSD1LossRate = _toUSD1LossRate;
  }

  /**
   * @dev get total assets in vault
   * @return total assets in vault (in USDC)
   */
  function getVaultTotalAssets() public view returns (uint256) {
    uint256 shareTokenShares = IERC20(shareToken).balanceOf(address(this));
    return IAsyncVault(vault).convertToAssets(shareTokenShares);
  }

  /**
   * @dev get conversion from USD1 to USDC
   * @param amount The amount of USD1 to convert
   * @return converted amount in USDC
   */
  function USD1ToUSDC(uint256 amount) public view returns (uint256) {
    return amount - amount.mulDiv(toUSDCLossRate, PRECISION);
  }

  /**
   * @dev get conversion from USDC to USD1
   * @param amount The amount of USDC to convert
   * @return converted amount in USD1
   */
  function USDCToUSD1(uint256 amount) public view returns (uint256) {
    return amount - amount.mulDiv(toUSD1LossRate, PRECISION);
  }

  /**
   * @dev allows manager to withdraw reward tokens for emergency or recover any other mistaken ERC20 tokens.
   * @param token ERC20 token address
   * @param amount token amount
   */
  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    IERC20(token).safeTransfer(msg.sender, amount);
    emit EmergencyWithdraw(token, amount);
  }

  /* INTERNAL FUNCTIONS */
  function _requestDepositToVault(uint256 amountUSDC) private {
    // approve amount to vault
    IERC20(USDC).safeIncreaseAllowance(vault, amountUSDC);
    // request deposit to vault
    IAsyncVault(vault).requestDeposit(amountUSDC, address(this), address(this));

    emit RequestDepositToVault(amountUSDC);
  }

  function _updateVaultAssets() private {
    uint256 newVaultTotalAssets = getVaultTotalAssets();
    uint256 totalInterest = newVaultTotalAssets - lastVaultTotalAssets;

    // charge fee, asset is USDC
    uint256 interestFee = totalInterest.mulDiv(feeRate, PRECISION);
    fee += interestFee;

    // convert to USD1
    uint256 interest = USDCToUSD1(totalInterest - interestFee);

    // notify interest to earn pool
    if (interest > 0) {
      IRWAEarnPool(earnPool).notifyInterest(interest);
    }
    // update lastVaultTotalAssets
    lastVaultTotalAssets = newVaultTotalAssets;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
