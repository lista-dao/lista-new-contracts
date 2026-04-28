// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAstherusVault } from "./interface/IAstherusVault.sol";
import { IAsterVault } from "./interface/IAsterVault.sol";
import { ILisAster } from "./interface/ILisAster.sol";

/// @title AsterVault
/// @notice The sole mint entry for lisAster. `deposit(amount, receiver)` forwards ASTER to the
///         AstherusVault BSC contract via `depositFor(asterToken, lisAsterManager, amount,
///         broker)`; Astherus's backend syncs the credited balance to the same EOA on Aster
///         Chain within 1-3 minutes. Then mints lisAster 1:1 to `receiver` atomically.
///         This contract itself never holds ASTER between transactions.
contract AsterVault is
  IAsterVault,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  UUPSUpgradeable
{
  using SafeERC20 for IERC20;

  /* CONSTANTS */
  bytes32 public constant PAUSER = keccak256("PAUSER");

  /* IMMUTABLE-LIKE (set once in initialize) */
  address public asterToken;
  address public astherusVault; // AstherusVault BSC contract (0x128463...)
  address public lisAster;
  address public lisAsterManager; // Lista-operated EOA on Astherus / Aster Chain (forAddress)

  /* MUTABLE STATE */
  uint256 public broker; // 4th parameter to AstherusVault.depositFor; Lista defaults to 1
  uint256 public minDeposit;

  /* EVENTS */
  event SetBroker(uint256 oldBroker, uint256 newBroker);
  event SetMinDeposit(uint256 oldMin, uint256 newMin);

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  /// @param admin             DEFAULT_ADMIN holder (governance multisig).
  /// @param pauser            PAUSER role holder.
  /// @param asterToken_       BSC ASTER token address.
  /// @param astherusVault_    AstherusVault BSC contract address.
  /// @param lisAster_         Deployed LisAster proxy.
  /// @param lisAsterManager_  Lista-operated EOA on Astherus / Aster Chain (the forAddress
  ///                          passed to depositFor).
  /// @param broker_           Initial broker flag (Lista default = 1).
  /// @param minDeposit_       Minimum deposit amount (recommended 0.1e18).
  function initialize(
    address admin,
    address pauser,
    address asterToken_,
    address astherusVault_,
    address lisAster_,
    address lisAsterManager_,
    uint256 broker_,
    uint256 minDeposit_
  ) external initializer {
    require(admin != address(0), "admin is zero");
    require(pauser != address(0), "pauser is zero");
    require(asterToken_ != address(0), "asterToken is zero");
    require(astherusVault_ != address(0), "astherusVault is zero");
    require(lisAster_ != address(0), "lisAster is zero");
    require(lisAsterManager_ != address(0), "lisAsterManager is zero");

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(PAUSER, pauser);

    asterToken = asterToken_;
    astherusVault = astherusVault_;
    lisAster = lisAster_;
    lisAsterManager = lisAsterManager_;
    broker = broker_;
    minDeposit = minDeposit_;
  }

  /* EXTERNAL */
  /// @inheritdoc IAsterVault
  function deposit(uint256 amount, address receiver) external override whenNotPaused nonReentrant {
    require(amount >= minDeposit, "amount < minDeposit");
    require(receiver != address(0), "receiver is zero");

    IERC20(asterToken).safeTransferFrom(msg.sender, address(this), amount);
    IERC20(asterToken).forceApprove(astherusVault, amount);
    IAstherusVault(astherusVault).depositFor(asterToken, lisAsterManager, amount, broker);
    IERC20(asterToken).forceApprove(astherusVault, 0);

    ILisAster(lisAster).mint(receiver, amount);

    emit Deposited(msg.sender, receiver, amount);
  }

  /* ADMIN */
  function setBroker(uint256 newBroker) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 oldBroker = broker;
    broker = newBroker;
    emit SetBroker(oldBroker, newBroker);
  }

  function setMinDeposit(uint256 newMin) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 oldMin = minDeposit;
    minDeposit = newMin;
    emit SetMinDeposit(oldMin, newMin);
  }

  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(PAUSER) {
    _unpause();
  }

  /* UUPS */
  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
