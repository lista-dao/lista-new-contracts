// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILendingRewardsDistributorV2 } from "./interface/ILendingRewardsDistributorV2.sol";
/**
 * @title RewardsRouter
 * @author Lista DAO
 * @dev Router for distributing rewards to distributors
 */
contract RewardsRouter is AccessControlEnumerableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
  using SafeERC20 for IERC20;

  /// @dev Distributors whitelist
  mapping(address => bool) public distributors;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  event TransferRewards(address indexed distributor, address indexed token, uint256 amount);
  event SetDistributorWhitelist(address indexed distributor, bool whitelisted);
  event EmergencyWithdrawal(address indexed to, address indexed token, uint256 amount);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @param _admin Address of the admin
   * @param _manager Address of the manager
   * @param _bot Address of the bot
   * @param _pauser Address of the pauser
   * @param _distributors Address of merkle reward distributors contract
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _pauser,
    address[] memory _distributors
  ) external initializer {
    require(_admin != address(0), "Invalid admin address");
    require(_manager != address(0), "Invalid manager address");
    require(_bot != address(0), "Invalid bot address");
    require(_pauser != address(0), "Invalid pauser address");
    require(_distributors.length > 0, "Empty tokens array");

    __Pausable_init();
    __AccessControl_init();
    __UUPSUpgradeable_init();

    for (uint256 i = 0; i < _distributors.length; i++) {
      require(_distributors[i] != address(0), "Invalid distributor address");
      distributors[_distributors[i]] = true;
      emit SetDistributorWhitelist(_distributors[i], true);
    }

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(BOT, _bot);
    _grantRole(PAUSER, _pauser);
  }

  /**
   * @dev Transfer rewards to a distributor; can only be called by a bot.
   * @param _token Address of the token to transfer
   * @param _distributor Address of the distributor
   * @param _amount Amount of tokens to transfer
   */
  function transferRewards(address _token, address _distributor, uint256 _amount) public whenNotPaused onlyRole(BOT) {
    require(_token != address(0), "Invalid token address");
    require(_distributor != address(0) && distributors[_distributor], "Invalid distributor address");
    require(_amount > 0, "Amount must be greater than zero");
    require(ILendingRewardsDistributorV2(_distributor).tokens(_token), "Token not supported by distributor");

    SafeERC20.safeTransfer(IERC20(_token), _distributor, _amount);

    emit TransferRewards(_distributor, _token, _amount);
  }

  /**
   * @dev Batch transfer rewards to multiple distributors; can only be called by a bot.
   * @param _tokens Array of token addresses to transfer
   * @param _distributors Array of distributor addresses
   * @param _amounts Array of amounts to transfer corresponding to each distributor
   */
  function batchTransferRewards(
    address[] memory _tokens,
    address[] memory _distributors,
    uint256[] memory _amounts
  ) external onlyRole(BOT) {
    require(_tokens.length == _distributors.length && _tokens.length == _amounts.length, "Array length mismatch");

    for (uint256 i = 0; i < _tokens.length; i++) {
      transferRewards(_tokens[i], _distributors[i], _amounts[i]);
    }
  }

  /// @dev Set distributor whitelist; can only be called by the manager.
  /// @param _distributors Array of distributor addresses
  /// @param _whitelisted Array of booleans indicating whether each distributor is whitelisted
  function setDistributorWhitelist(
    address[] memory _distributors,
    bool[] memory _whitelisted
  ) external whenNotPaused onlyRole(MANAGER) {
    require(_distributors.length == _whitelisted.length, "Array length mismatch");

    for (uint256 i = 0; i < _distributors.length; i++) {
      require(_distributors[i] != address(0), "Invalid distributor address");
      distributors[_distributors[i]] = _whitelisted[i];

      emit SetDistributorWhitelist(_distributors[i], _whitelisted[i]);
    }
  }

  /// @dev manager can withdraw all reward tokens from the contract in case of emergency
  /// @param token Address of the token to withdraw
  function emergencyWithdraw(address token) external onlyRole(MANAGER) {
    uint256 _amount = IERC20(token).balanceOf(address(this));
    IERC20(token).safeTransfer(msg.sender, _amount);

    emit EmergencyWithdrawal(msg.sender, token, _amount);
  }

  /// @dev pause the contract
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  /// @dev unpause the contract
  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
