// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CreditFundBase } from "./CreditFundBase.sol";
import { CreditFundSharePool } from "./CreditFundSharePool.sol";

/**
 * @title FlexEarnPool
 * @notice Flexible (demand) product of the Surfin Credit Fund.
 *
 * Principal is tracked 1:1 as an ERC20 LP (deposit mints, withdraw burns).
 * Interest is distributed off-pool via the cumulative Merkle InterestDistributor.
 * Withdrawals go through the shared daily batch queue and are irreversible once
 * submitted: the LP is burned at request time and there is no cancel path.
 * The cap bounds the outstanding LP supply.
 */
contract FlexEarnPool is CreditFundSharePool {
  using SafeERC20 for IERC20;

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  function initialize(
    address _admin,
    address _manager,
    address _pauser,
    address _bot,
    address _asset,
    address _adapter,
    string memory _name,
    string memory _symbol
  ) external initializer {
    __CreditFundSharePool_init(_admin, _manager, _pauser, _bot, _asset, _adapter, _name, _symbol);
  }

  /* EXTERNAL FUNCTIONS */
  /**
   * @dev deposit asset into the flex pool; funds go straight to the adapter.
   * @param amount the amount of asset to deposit
   * @param receiver the receiver of the LP
   */
  function deposit(uint256 amount, address receiver) external whenNotPaused whenDepositNotPaused nonReentrant {
    _checkDeposit(receiver, amount);

    // mint 1:1 LP and forward funds to the adapter
    _mint(receiver, amount);
    IERC20(asset).safeTransferFrom(msg.sender, adapter, amount);

    emit Deposit(receiver, amount);
  }

  /**
   * @dev request to withdraw principal; burns LP and queues into the batch.
   * @param amount the amount of principal to withdraw, or `type(uint256).max` for the
   *        whole balance
   */
  function requestWithdraw(uint256 amount) external whenNotPaused nonReentrant {
    amount = _resolveAll(amount);
    require(amount > 0, "amount is zero");
    require(balanceOf(msg.sender) >= amount, "insufficient balance");

    // min-withdraw floor with dust exit: a sub-min request must drain the balance
    _checkMinWithdraw(msg.sender, amount, amount, balanceOf(msg.sender));

    // enforce per-address daily submit limit
    _consumeDailyLimit(msg.sender, amount);

    // burn LP and enqueue
    _burn(msg.sender, amount);
    uint256 batchId = _enqueueWithdraw(msg.sender, amount, 0);

    emit RequestWithdraw(msg.sender, msg.sender, batchId, amount);
  }

  /* VIEWS */
  /// @inheritdoc CreditFundBase
  function totalPrincipal() public view override returns (uint256) {
    return totalSupply();
  }

  /* INTERNAL FUNCTIONS */
  /// @dev the LP is 1:1, so the outstanding supply is the pool's size
  function _capUsage() internal view override returns (uint256) {
    return totalSupply();
  }

  uint256[50] private __gap;
}
