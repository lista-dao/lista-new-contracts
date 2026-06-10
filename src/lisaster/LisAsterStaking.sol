// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILisAsterStaking } from "./interface/ILisAsterStaking.sol";

/// @title LisAsterStaking
/// @notice Pure staking position contract. Users deposit lisAster here as proof of
///         participation; this contract holds no reward ledger and does not push snapshots
///         to the Distributor. The off-chain backend reads `balanceOf` on a randomized cadence
///         and aggregates the Merkle tree.
contract LisAsterStaking is
  ILisAsterStaking,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  UUPSUpgradeable
{
  using SafeERC20 for IERC20;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  /* IMMUTABLE-LIKE (set once in initialize) */
  address public lisAster;

  /* STATE */
  mapping(address => uint256) public override balanceOf;
  uint256 public override totalSupply;

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  function initialize(address admin, address pauser, address manager, address lisAster_) external initializer {
    require(admin != address(0), "admin is zero");
    require(pauser != address(0), "pauser is zero");
    require(manager != address(0), "manager is zero");
    require(lisAster_ != address(0), "lisAster is zero");

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(PAUSER, pauser);
    _grantRole(MANAGER, manager);

    lisAster = lisAster_;
  }

  /* EXTERNAL */
  function stake(uint256 amount) external override whenNotPaused nonReentrant {
    _stake(msg.sender, amount);
  }

  /// @notice Stake on behalf of `receiver`. Permissionless: any caller may stake their own
  ///         lisAster into someone else's position.
  function stakeFor(address receiver, uint256 amount) external override whenNotPaused nonReentrant {
    _stake(receiver, amount);
  }

  function unstake(uint256 amount) external override whenNotPaused nonReentrant {
    require(amount > 0, "zero amount");
    require(balanceOf[msg.sender] >= amount, "insufficient balance");
    balanceOf[msg.sender] -= amount;
    totalSupply -= amount;
    IERC20(lisAster).safeTransfer(msg.sender, amount);
    emit Unstaked(msg.sender, amount);
  }

  /* ADMIN */
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(PAUSER) {
    _unpause();
  }

  /// @notice Rescue stuck or mis-routed tokens. Funds are sent to the MANAGER caller.
  ///         Mirrors `LisAsterDistributor.emergencyWithdraw` -- pure escape hatch, no
  ///         accounting protection. Withdrawing lisAster will break the
  ///         `balanceOf(this) >= totalSupply` invariant; pause first and reconcile by runbook.
  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    require(token != address(0), "zero token");
    require(amount > 0, "zero amount");
    IERC20(token).safeTransfer(msg.sender, amount);
    emit EmergencyWithdrawn(token, msg.sender, amount);
  }

  /* INTERNAL */
  function _stake(address receiver, uint256 amount) private {
    require(receiver != address(0), "receiver is zero");
    require(amount > 0, "zero amount");
    balanceOf[receiver] += amount;
    totalSupply += amount;
    IERC20(lisAster).safeTransferFrom(msg.sender, address(this), amount);
    emit Staked(msg.sender, receiver, amount);
  }

  /* UUPS */
  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
