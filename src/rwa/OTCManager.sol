// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OTCManager is AccessControlEnumerableUpgradeable, UUPSUpgradeable {
  using SafeERC20 for IERC20;

  /* VARIABLES */
  address public adapter;
  address public otcWallet;

  /* IMMUTABLES */
  address public immutable USD1;
  address public immutable USDC;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");

  /* EVENTS */
  event EmergencyWithdraw(address token, uint256 amount);
  event OTCWalletChanged(address newOTCWallet);
  event TransferToAdapter(address token, uint256 amount);
  event SwapToken(address token, uint256 amount);

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
   * @param _adapter The address of the adapter.
   * @param _otcWallet The address of the OTC wallet.
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _adapter,
    address _otcWallet
  ) external initializer {
    require(_admin != address(0), "Admin is zero address");
    require(_manager != address(0), "Manager is zero address");
    require(_adapter != address(0), "Adapter is zero address");
    require(_otcWallet != address(0), "OTC wallet is zero address");
    require(_bot != address(0), "Bot is zero address");

    __AccessControlEnumerable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(BOT, _bot);

    adapter = _adapter;
    otcWallet = _otcWallet;
  }

  /* EXTERNAL FUNCTIONS */
  /**
   * @dev swaps tokens from adapter to OTC wallet.
   * @param token The address of the token to swap (USD1 or USDC).
   * @param amount The amount of tokens to swap.
   */
  function swapToken(address token, uint256 amount) external {
    require(msg.sender == adapter, "Only adapter can call this function");
    require(token == USD1 || token == USDC, "Invalid token");
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    IERC20(token).safeTransfer(otcWallet, amount);

    emit SwapToken(token, amount);
  }

  /**
   * @dev transfers tokens from OTC wallet to adapter.
   * @param token The address of the token to transfer (USD1 or USDC).
   * @param amount The amount of tokens to transfer.
   */
  function transferToAdapter(address token, uint256 amount) external onlyRole(BOT) {
    require(amount > 0, "Amount must be greater than zero");
    require(token == USD1 || token == USDC, "Invalid token");
    IERC20(token).safeTransfer(adapter, amount);

    emit TransferToAdapter(token, amount);
  }

  /**
   * @dev allows manager to withdraw tokens for emergency
   * @param token ERC20 token address
   * @param amount token amount
   * @param receiver address to receive the tokens
   */
  function emergencyWithdraw(address token, uint256 amount, address receiver) external onlyRole(MANAGER) {
    require(amount > 0, "Amount must be greater than zero");
    require(receiver != address(0), "Receiver is zero address");
    IERC20(token).safeTransfer(receiver, amount);
    emit EmergencyWithdraw(token, amount);
  }

  function setOTCWallet(address _otcWallet) external onlyRole(MANAGER) {
    require(_otcWallet != address(0), "OTC wallet is zero address");
    require(_otcWallet != otcWallet, "OTC wallet is the same");
    otcWallet = _otcWallet;

    emit OTCWalletChanged(_otcWallet);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
