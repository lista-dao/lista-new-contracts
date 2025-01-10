// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interface/ILpToken.sol";

contract BeraChainVaultAdapter is
  Initializable,
  AccessControlUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  UUPSUpgradeable
{
  using SafeERC20 for IERC20;
  // manager role
  bytes32 public constant MANAGER = keccak256("MANAGER");
  // pause role
  bytes32 public constant PAUSER = keccak256("PAUSER");
  // bot role
  bytes32 public constant BOT = keccak256("BOT");

  IERC20 public token;

  ILpToken public lpToken;

  // a multi-sig with high threshold
  address public operator;

  uint256 public depositEndTime;

  /**
   * Events
   */
  event ChangeDepositEndTime(uint256 endTime);
  event ChangeOperator(address indexed operator);
  event Deposit(address indexed account, uint256 amount);
  event SystemWithdraw(address indexed receiver, uint256 amount);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Initialize the contract
   * @param _admin address
   * @param _manager address
   * @param _pauser address
   * @param _bot address
   * @param _token address
   * @param _lpToken address
   * @param _operator address
   * @param _depositEndTime uint256
   */
  function initialize(
    address _admin,
    address _manager,
    address _pauser,
    address _bot,
    address _token,
    address _lpToken,
    address _operator,
    uint256 _depositEndTime
  ) public initializer {
    require(_admin != address(0), "admin is the zero address");
    require(_manager != address(0), "manager is the zero address");
    require(_pauser != address(0), "pauser is the zero address");
    require(_bot != address(0), "bot is the zero address");
    require(_token != address(0), "token is the zero address");
    require(_lpToken != address(0), "lpToken is the zero address");
    require(_operator != address(0), "botWithdrawReceiver is the zero address");
    require(_depositEndTime > block.timestamp, "invalid depositEndTime");

    __AccessControl_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);
    _grantRole(BOT, _bot);

    token = IERC20(_token);
    lpToken = ILpToken(_lpToken);
    operator = _operator;
    depositEndTime = _depositEndTime;
  }

  /**
   * @dev deposit given amount of token to the vault
   * @param _amount amount of token to deposit
   */
  function deposit(uint256 _amount) external nonReentrant whenNotPaused returns (uint256) {
    require(_amount > 0, "invalid amount");
    require(block.timestamp <= depositEndTime, "deposit closed");

    token.safeTransferFrom(msg.sender, address(this), _amount);
    lpToken.mint(msg.sender, _amount);

    emit Deposit(msg.sender, _amount);
    return _amount;
  }

  /**
   * @dev withdraw given amount of token from the vault by manager
   * @param _receiver address to receive the token
   * @param _amount amount of token to withdraw
   */
  function managerWithdraw(
    address _receiver,
    uint256 _amount
  ) external onlyRole(MANAGER) nonReentrant whenNotPaused returns (uint256) {
    require(_receiver != address(0), "invalid receiver");
    require(_amount > 0, "invalid amount");
    require(token.balanceOf(address(this)) >= _amount, "insufficient balance");

    token.safeTransfer(_receiver, _amount);
    emit SystemWithdraw(_receiver, _amount);
    return _amount;
  }

  /**
   * @dev withdraw given amount of token from the vault by bot
   * @param _amount amount of token to withdraw
   */
  function botWithdraw(uint256 _amount) external onlyRole(BOT) nonReentrant whenNotPaused returns (uint256) {
    require(_amount > 0, "invalid amount");
    require(token.balanceOf(address(this)) >= _amount, "insufficient balance");

    token.safeTransfer(operator, _amount);
    emit SystemWithdraw(operator, _amount);
    return _amount;
  }

  /**
   * @dev change operator
   * @param _operator new address
   */
  function setOperator(address _operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_operator != address(0), "invalid operator");
    require(_operator != operator, "same operator");

    operator = _operator;
    emit ChangeOperator(operator);
  }

  /**
   * @dev change deposit end time, extend or reduce deposit end time
   * @param _depositEndTime new end time
   */
  function setDepositEndTime(uint256 _depositEndTime) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_depositEndTime != depositEndTime, "same depositEndTime");

    depositEndTime = _depositEndTime;
    emit ChangeDepositEndTime(depositEndTime);
  }

  /**
   * PAUSABLE FUNCTIONALITY
   */
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  /**
   * UUPSUpgradeable FUNCTIONALITY
   */
  function _authorizeUpgrade(address _newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
