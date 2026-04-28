// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAsterVault } from "./interface/IAsterVault.sol";
import { ILisAsterDistributor } from "./interface/ILisAsterDistributor.sol";
import { ILisAsterRewards } from "./interface/ILisAsterRewards.sol";

/// @title LisAsterRewards
/// @notice Reward converter and staging pool. MANAGER calls `notifyRewards` to forward
///         ASTER returned via AstherusVault.withdraw through AsterVault.deposit, which mints
///         lisAster back to this contract. BOT then calls `distributeRewards` to forward
///         accumulated lisAster to the Distributor and bump its `totalNotified`. This
///         contract itself does not hold the MINTER role.
contract LisAsterRewards is
  ILisAsterRewards,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  UUPSUpgradeable
{
  using SafeERC20 for IERC20;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  /* IMMUTABLE-LIKE (set once in initialize) */
  address public asterToken;
  address public lisAster;
  address public vault;

  /* SET-ONCE (one-shot setter, breaks circular dep) */
  address public distributor;

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  function initialize(
    address admin,
    address pauser,
    address manager,
    address bot,
    address asterToken_,
    address lisAster_,
    address vault_
  ) external initializer {
    require(admin != address(0), "admin is zero");
    require(pauser != address(0), "pauser is zero");
    require(manager != address(0), "manager is zero");
    require(bot != address(0), "bot is zero");
    require(asterToken_ != address(0), "asterToken is zero");
    require(lisAster_ != address(0), "lisAster is zero");
    require(vault_ != address(0), "vault is zero");

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(PAUSER, pauser);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);

    asterToken = asterToken_;
    lisAster = lisAster_;
    vault = vault_;
  }

  /* ONE-SHOT SETTER */
  function setDistributor(address d) external onlyRole(MANAGER) {
    require(distributor == address(0), "distributor already set");
    require(d != address(0), "zero");
    distributor = d;
    emit DistributorSet(d);
  }

  /* EXTERNAL */
  function notifyRewards(uint256 amount) external override onlyRole(MANAGER) whenNotPaused nonReentrant {
    require(amount > 0, "zero amount");

    uint256 balBefore = IERC20(lisAster).balanceOf(address(this));
    IERC20(asterToken).safeTransferFrom(msg.sender, address(this), amount);
    IERC20(asterToken).forceApprove(vault, amount);
    IAsterVault(vault).deposit(amount, address(this));
    IERC20(asterToken).forceApprove(vault, 0);

    // Strict 1:1 invariant: AsterVault.deposit always mints exactly `amount` lisAster.
    // If Vault ever introduces an exchange rate or fee, this assertion must be revisited.
    uint256 minted = IERC20(lisAster).balanceOf(address(this)) - balBefore;
    require(minted == amount, "mint mismatch");

    emit RewardsNotified(amount, minted);
  }

  function distributeRewards(uint256 amount) external override onlyRole(BOT) whenNotPaused nonReentrant {
    require(amount > 0, "zero amount");
    require(distributor != address(0), "distributor not set");
    require(amount <= IERC20(lisAster).balanceOf(address(this)), "exceeds balance");

    IERC20(lisAster).forceApprove(distributor, amount);
    ILisAsterDistributor(distributor).notifyRewards(amount);
    IERC20(lisAster).forceApprove(distributor, 0);

    emit RewardsDistributed(amount);
  }

  /* VIEW */
  function pendingLisAster() external view override returns (uint256) {
    return IERC20(lisAster).balanceOf(address(this));
  }

  /* ADMIN */
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(PAUSER) {
    _unpause();
  }

  /* UUPS */
  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
