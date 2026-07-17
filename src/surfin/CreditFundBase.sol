// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CreditFundBase
 * @notice Shared base for the Surfin flex/locked earn pools.
 *
 * Design follows lista-new-contracts/src/rwa/RWAEarnPool.sol:
 *  - deposits transfer funds straight to the adapter (pool keeps only accounting);
 *  - withdrawals go through a daily batch queue that the adapter repays via
 *    `finishWithdraw`, then users `claimWithdraw`;
 *  - interest is booked separately from principal (principal is claimed as batch
 *    withdrawals, interest is claimed via `claimInterest`).
 *
 * Principal bookkeeping differs between products (1:1 LP for flex, positions for
 * locked) so `totalPrincipal` and the deposit/withdraw entrypoints are left to
 * the child contract; everything shared lives here.
 */
abstract contract CreditFundBase is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  /* STRUCTS */
  // batchId: batch the request belongs to
  // withdrawTime: timestamp of the request
  // amount: principal payout to release
  struct WithdrawalRequest {
    uint256 batchId;
    uint256 withdrawTime;
    uint256 amount;
  }

  /* VARIABLES */
  // asset token address (USDT)
  address public asset;
  // adapter address (holds the funds, drives the pool)
  address public adapter;
  // pool display name / symbol
  string public name;
  string public symbol;

  // user => withdrawal requests
  mapping(address => WithdrawalRequest[]) internal userWithdrawalRequests;
  // batch id => total withdraw amount in the batch
  mapping(uint256 => uint256) public totalWithdrawAmountInBatch;
  // amount received from adapter but not yet assigned to a confirmed batch
  uint256 public withdrawQuota;
  // current (open) batch id
  uint256 public currentBatchId;
  // last confirmed batch id
  uint256 public confirmedBatchId;
  // last epoch day a batch was opened
  uint256 public lastDay;
  // total principal requested for withdraw but not yet claimed
  uint256 public totalPendingWithdraw;

  // user => claimable interest booked by the adapter
  mapping(address => uint256) public claimableInterest;
  // total interest funds held for claims
  uint256 public interestQuota;

  // per-address per-day submitted withdraw amount, 0 disables the limit
  uint256 public dailyLimit;
  // epoch day => user => submitted amount
  mapping(uint256 => mapping(address => uint256)) public dailySubmitted;

  // deposit whitelist (empty => open to all)
  EnumerableSet.AddressSet internal whitelist;
  // minimum deposit amount, in asset units
  uint256 public minDeposit;

  /* CONSTANTS */
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant BOT = keccak256("BOT");
  uint256 public constant PRECISION = 1 ether;

  /* EVENTS */
  event Transfer(address indexed from, address indexed to, uint256 value);
  event Deposit(address indexed user, uint256 amount);
  event RequestWithdraw(address indexed owner, address indexed receiver, uint256 batchId, uint256 amount);
  event FinishWithdraw(uint256 batchId, uint256 amount);
  event ClaimWithdrawal(address indexed user, uint256 idx, uint256 amount);
  event CancelWithdrawal(address indexed user, uint256 idx, uint256 amount);
  event AddClaimableInterest(uint256 total);
  event ClaimInterest(address indexed user, uint256 amount);
  event WhiteListChanged(address user, bool ok);
  event SetMinDeposit(uint256 minDeposit);
  event SetDailyLimit(uint256 dailyLimit);
  event SetAdapter(address adapter);
  event EmergencyWithdraw(address token, uint256 amount);

  /* INITIALIZER */
  function __CreditFundBase_init(
    address _admin,
    address _manager,
    address _pauser,
    address _bot,
    address _asset,
    address _adapter,
    string memory _name,
    string memory _symbol
  ) internal onlyInitializing {
    require(_admin != address(0), "admin is zero address");
    require(_manager != address(0), "manager is zero address");
    require(_pauser != address(0), "pauser is zero address");
    require(_bot != address(0), "bot is zero address");
    require(_asset != address(0), "asset is zero address");
    require(_adapter != address(0), "adapter is zero address");
    require(bytes(_name).length > 0, "name is empty");
    require(bytes(_symbol).length > 0, "symbol is empty");

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);
    _grantRole(BOT, _bot);

    asset = _asset;
    adapter = _adapter;
    name = _name;
    symbol = _symbol;
  }

  /* ABSTRACT */
  /// @dev total user principal booked in the pool
  function totalPrincipal() external view virtual returns (uint256);

  /* ADAPTER-DRIVEN FUNCTIONS */
  /**
   * @dev repay the batch withdraw queue. Only the adapter can call.
   * @param amount asset amount transferred in to cover pending batches (0 allowed to just tick batches)
   */
  function finishWithdraw(uint256 amount) external {
    require(msg.sender == adapter, "only adapter can call");

    if (amount > 0) {
      IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
      withdrawQuota += amount;
    }

    // confirm as many batches as the quota can fully cover, in order
    for (uint256 i = confirmedBatchId + 1; i <= currentBatchId; i++) {
      uint256 withdrawAmount = totalWithdrawAmountInBatch[i];
      if (withdrawAmount > withdrawQuota) {
        break;
      }
      confirmedBatchId = i;
      withdrawQuota -= withdrawAmount;
      emit FinishWithdraw(i, withdrawAmount);
    }
  }

  /**
   * @dev book claimable interest for a set of users. Only the adapter can call.
   *      The adapter transfers the summed interest in first.
   * @param users the users to credit
   * @param amounts the interest amount for each user
   */
  function addClaimableInterest(address[] calldata users, uint256[] calldata amounts) external {
    require(msg.sender == adapter, "only adapter can call");
    require(users.length == amounts.length, "length mismatch");

    uint256 total;
    for (uint256 i = 0; i < users.length; i++) {
      require(users[i] != address(0), "user is zero address");
      claimableInterest[users[i]] += amounts[i];
      total += amounts[i];
    }

    if (total > 0) {
      IERC20(asset).safeTransferFrom(msg.sender, address(this), total);
      interestQuota += total;
    }

    emit AddClaimableInterest(total);
  }

  /* USER FUNCTIONS */
  /**
   * @dev claim principal of a confirmed withdrawal request.
   * @param user the owner of the request
   * @param idx the index of the request
   */
  function claimWithdraw(address user, uint256 idx) external whenNotPaused nonReentrant {
    WithdrawalRequest[] storage reqs = userWithdrawalRequests[user];
    require(idx < reqs.length, "invalid index");

    WithdrawalRequest memory req = reqs[idx];
    require(req.batchId <= confirmedBatchId, "not able to claim yet");

    // swap-pop remove
    reqs[idx] = reqs[reqs.length - 1];
    reqs.pop();

    totalPendingWithdraw -= req.amount;
    IERC20(asset).safeTransfer(user, req.amount);

    emit ClaimWithdrawal(user, idx, req.amount);
  }

  /**
   * @dev claim all booked interest for the caller.
   */
  function claimInterest() external whenNotPaused nonReentrant {
    uint256 amount = claimableInterest[msg.sender];
    require(amount > 0, "no claimable interest");

    claimableInterest[msg.sender] = 0;
    interestQuota -= amount;
    IERC20(asset).safeTransfer(msg.sender, amount);

    emit ClaimInterest(msg.sender, amount);
  }

  /* VIEWS */
  function getUserWithdrawalRequests(address user) external view returns (WithdrawalRequest[] memory) {
    return userWithdrawalRequests[user];
  }

  function decimals() external pure returns (uint8) {
    return 18;
  }

  function isInWhitelist(address user) public view returns (bool) {
    return whitelist.length() == 0 || whitelist.contains(user);
  }

  function getWhiteList() external view returns (address[] memory) {
    return whitelist.values();
  }

  /* MANAGER FUNCTIONS */
  function setWhiteList(address user, bool ok) external onlyRole(MANAGER) {
    require(user != address(0), "user is zero address");
    require(whitelist.contains(user) != ok, "same status");
    if (ok) {
      whitelist.add(user);
    } else {
      whitelist.remove(user);
    }
    emit WhiteListChanged(user, ok);
  }

  function setMinDeposit(uint256 _minDeposit) external onlyRole(MANAGER) {
    require(minDeposit != _minDeposit, "same minDeposit");
    minDeposit = _minDeposit;
    emit SetMinDeposit(_minDeposit);
  }

  function setDailyLimit(uint256 _dailyLimit) external onlyRole(MANAGER) {
    require(dailyLimit != _dailyLimit, "same dailyLimit");
    dailyLimit = _dailyLimit;
    emit SetDailyLimit(_dailyLimit);
  }

  function setAdapter(address _adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_adapter != address(0), "adapter is zero address");
    require(_adapter != adapter, "same adapter");
    adapter = _adapter;
    emit SetAdapter(_adapter);
  }

  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  /**
   * @dev emergency token rescue. Interest/withdraw funds live in the pool, so
   *      restrict to admin.
   */
  function emergencyWithdraw(address token, uint256 amount, address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(amount > 0, "amount is zero");
    require(receiver != address(0), "receiver is zero address");
    IERC20(token).safeTransfer(receiver, amount);
    emit EmergencyWithdraw(token, amount);
  }

  /* INTERNAL HELPERS */
  /**
   * @dev enqueue a withdrawal request into the current/open batch.
   * @param receiver the receiver of the payout
   * @param amount the principal payout to queue
   */
  function _enqueueWithdraw(address receiver, uint256 amount) internal returns (uint256 batchId) {
    // open a new batch on a new day, or when the current batch is already confirmed
    uint256 day = block.timestamp / 1 days;
    if (day > lastDay) {
      lastDay = day;
      ++currentBatchId;
    } else if (currentBatchId == confirmedBatchId) {
      ++currentBatchId;
    }
    batchId = currentBatchId;

    userWithdrawalRequests[receiver].push(
      WithdrawalRequest({ batchId: batchId, amount: amount, withdrawTime: block.timestamp })
    );
    totalWithdrawAmountInBatch[batchId] += amount;
    totalPendingWithdraw += amount;
  }

  /**
   * @dev remove an unconfirmed withdrawal request (for cancellation). Returns its amount.
   */
  function _removeWithdrawRequest(address user, uint256 idx) internal returns (uint256 amount) {
    WithdrawalRequest[] storage reqs = userWithdrawalRequests[user];
    require(idx < reqs.length, "invalid index");

    WithdrawalRequest memory req = reqs[idx];
    require(req.batchId > confirmedBatchId, "already confirmed");

    reqs[idx] = reqs[reqs.length - 1];
    reqs.pop();

    totalWithdrawAmountInBatch[req.batchId] -= req.amount;
    totalPendingWithdraw -= req.amount;
    amount = req.amount;
  }

  /**
   * @dev check and consume the per-address daily submit limit.
   */
  function _consumeDailyLimit(address user, uint256 amount) internal {
    if (dailyLimit > 0) {
      uint256 day = block.timestamp / 1 days;
      require(dailySubmitted[day][user] + amount <= dailyLimit, "exceeds daily limit");
      dailySubmitted[day][user] += amount;
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  // reserve storage for future upgrades
  uint256[45] private __gap;
}
