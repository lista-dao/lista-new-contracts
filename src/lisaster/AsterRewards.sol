// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILisAsterDistributor } from "./interface/ILisAsterDistributor.sol";
import { IAsterRewards } from "./interface/IAsterRewards.sol";

/// @title AsterRewards
/// @notice ASTER reward pool + dispatcher. BOT calls `notifyRewards` to ingest ASTER from
///         `operator` (returned via AstherusVault.withdraw); an optional fee is forwarded
///         to `feeReceiver` and the net stays here as ASTER. BOT calls `distributeRewards` to push
///         accumulated ASTER to the Distributor, which pulls via `transferFrom` and bumps
///         `totalNotified`.
contract AsterRewards is
  IAsterRewards,
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

  uint256 public constant PRECISION = 1e18;
  uint256 public constant MAX_FEE_RATE = 3e17; // 30%

  /* IMMUTABLE-LIKE (set once in initialize) */
  address public asterToken;

  /* SET-ONCE (one-shot setter, breaks circular dep) */
  address public distributor;

  /* FEE (MANAGER tunable; default 0 = no fee) */
  address public feeReceiver;
  uint256 public feeRate; // 18 decimals (1e18 = 100%); MANAGER capped by MAX_FEE_RATE

  /* REWARD SOURCE (MANAGER tunable; notifyRewards transferFrom source) */
  /// @notice Lista-operated EOA on Astherus / Aster Chain; the ASTER reward source pulled by
  ///         `notifyRewards`. Same entity/address as `AsterVault.lisAsterManager`. It must
  ///         `approve` ASTER to this contract before BOT calls `notifyRewards`.
  address public operator;

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
    address asterToken_
  ) external initializer {
    require(admin != address(0), "admin is zero");
    require(pauser != address(0), "pauser is zero");
    require(manager != address(0), "manager is zero");
    require(bot != address(0), "bot is zero");
    require(asterToken_ != address(0), "asterToken is zero");

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(PAUSER, pauser);
    _grantRole(MANAGER, manager);
    _grantRole(BOT, bot);

    asterToken = asterToken_;
  }

  /* ONE-SHOT SETTER */
  function setDistributor(address d) external onlyRole(MANAGER) {
    require(distributor == address(0), "distributor already set");
    require(d != address(0), "zero");
    distributor = d;
    emit DistributorSet(d);
  }

  /* FEE SETTERS */
  function setFeeReceiver(address r) external onlyRole(MANAGER) {
    require(r != address(0), "feeReceiver is zero");
    feeReceiver = r;
    emit SetFeeReceiver(r);
  }

  function setFeeRate(uint256 r) external onlyRole(MANAGER) {
    require(r <= MAX_FEE_RATE, "feeRate too high");
    feeRate = r;
    emit SetFeeRate(r);
  }

  /* REWARD-SOURCE SETTER */
  function setOperator(address newOperator) external onlyRole(MANAGER) {
    require(newOperator != address(0), "operator is zero");
    address oldOperator = operator;
    operator = newOperator;
    emit SetOperator(oldOperator, newOperator);
  }

  /* EXTERNAL */
  function notifyRewards(uint256 amount) external override onlyRole(BOT) whenNotPaused nonReentrant {
    require(amount > 0, "zero amount");
    require(operator != address(0), "operator not set");

    IERC20(asterToken).safeTransferFrom(operator, address(this), amount);

    // Take fee only when both knobs are configured. Either feeRate=0 or feeReceiver=0 means
    // no fee for this round -- MANAGER can stage the two settings in any order without
    // bricking notifyRewards in between.
    uint256 fee = 0;
    if (feeRate > 0 && feeReceiver != address(0)) {
      fee = (amount * feeRate) / PRECISION;
      if (fee > 0) {
        IERC20(asterToken).safeTransfer(feeReceiver, fee);
      }
    }
    uint256 net = amount - fee;
    require(net > 0, "net is zero");

    emit RewardsNotified(amount, fee, net);
  }

  function distributeRewards(uint256 amount) external override onlyRole(BOT) whenNotPaused nonReentrant {
    require(amount > 0, "zero amount");
    require(distributor != address(0), "distributor not set");
    require(amount <= IERC20(asterToken).balanceOf(address(this)), "exceeds balance");

    IERC20(asterToken).forceApprove(distributor, amount);
    ILisAsterDistributor(distributor).notifyRewards(amount);

    emit RewardsDistributed(amount);
  }

  /* VIEW */
  function pendingAster() external view override returns (uint256) {
    return IERC20(asterToken).balanceOf(address(this));
  }

  /* ADMIN */
  /// @notice PAUSER can fast-trip the contract in an incident;
  ///         resuming requires the MANAGER multisig to deliberate.
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  /// @notice MANAGER escape hatch for stuck / over-pulled ASTER or mis-sent tokens. Funds are
  ///         sent to the MANAGER caller. Does not adjust accounting (this contract holds no
  ///         cumulative state). BOT deliberately has no access.
  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    require(token != address(0), "zero token");
    require(amount > 0, "zero amount");
    IERC20(token).safeTransfer(msg.sender, amount);
    emit EmergencyWithdrawn(token, msg.sender, amount);
  }

  /* UUPS */
  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
