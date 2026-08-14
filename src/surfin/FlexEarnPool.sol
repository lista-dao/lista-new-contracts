// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CreditFundBase } from "./CreditFundBase.sol";

/**
 * @title FlexEarnPool
 * @notice Flexible (demand) product of the Surfin Credit Fund.
 *
 * Principal is tracked 1:1 as an LP balance (deposit mints, withdraw burns).
 * Interest is distributed off-pool via the cumulative Merkle InterestDistributor.
 * Withdrawals go through the shared daily batch queue; unconfirmed requests can
 * be cancelled in full, restoring the LP with no interest loss.
 */
contract FlexEarnPool is CreditFundBase {
  using SafeERC20 for IERC20;

  /* VARIABLES */
  // user => LP balance (1:1 with principal)
  mapping(address => uint256) public balanceOf;
  // total LP supply
  uint256 public totalSupply;

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
    __CreditFundBase_init(_admin, _manager, _pauser, _bot, _asset, _adapter, _name, _symbol);
  }

  /* EXTERNAL FUNCTIONS */
  /**
   * @dev deposit asset into the flex pool; funds go straight to the adapter.
   * @param amount the amount of asset to deposit
   * @param receiver the receiver of the LP
   */
  function deposit(uint256 amount, address receiver) external whenNotPaused whenDepositNotPaused nonReentrant {
    require(amount > 0, "amount is zero");
    require(receiver != address(0), "receiver is zero address");
    require(amount >= minDeposit, "deposit below minimum");

    // mint 1:1 LP and forward funds to the adapter
    _mint(receiver, amount);
    IERC20(asset).safeTransferFrom(msg.sender, adapter, amount);

    emit Deposit(receiver, amount);
  }

  /**
   * @dev request to withdraw principal; burns LP and queues into the batch.
   * @param amount the amount of principal to withdraw
   */
  function requestWithdraw(uint256 amount) external whenNotPaused nonReentrant {
    require(amount > 0, "amount is zero");
    require(balanceOf[msg.sender] >= amount, "insufficient balance");

    // min-withdraw floor with dust exit: a sub-min request must drain the balance and
    // leave nothing cancellable behind it
    _checkMinWithdraw(msg.sender, amount, balanceOf[msg.sender]);

    // enforce per-address daily submit limit
    _consumeDailyLimit(msg.sender, amount);

    // burn LP and enqueue
    _burn(msg.sender, amount);
    uint256 batchId = _enqueueWithdraw(msg.sender, amount, 0);

    emit RequestWithdraw(msg.sender, msg.sender, batchId, amount);
  }

  /**
   * @dev cancel an unconfirmed withdrawal request in full; restores the LP.
   * @param idx the index of the caller's withdrawal request
   * @param expectedAmount the expected request amount; guards against swap-and-pop index drift
   */
  function cancelWithdraw(uint256 idx, uint256 expectedAmount) external whenNotPaused nonReentrant {
    uint256 amount = _removeWithdrawRequest(msg.sender, idx, expectedAmount);
    _mint(msg.sender, amount);

    emit CancelWithdrawal(msg.sender, idx, amount);
  }

  /* VIEWS */
  /// @inheritdoc CreditFundBase
  function totalPrincipal() public view override returns (uint256) {
    return totalSupply;
  }

  /// @inheritdoc CreditFundBase
  /// @dev this pool exposes `cancelWithdraw`, so an unconfirmed request here can be
  ///      turned back into LP and must be counted by the dust-exit check.
  function _cancelSupported() internal pure override returns (bool) {
    return true;
  }

  /* INTERNAL FUNCTIONS */
  function _mint(address account, uint256 amount) internal {
    balanceOf[account] += amount;
    totalSupply += amount;
    emit Transfer(address(0), account, amount);
  }

  function _burn(address account, uint256 amount) internal {
    require(balanceOf[account] >= amount, "burn amount exceeds balance");
    balanceOf[account] -= amount;
    totalSupply -= amount;
    emit Transfer(account, address(0), amount);
  }

  uint256[50] private __gap;
}
