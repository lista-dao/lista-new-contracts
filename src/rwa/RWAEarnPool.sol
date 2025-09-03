// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RWAEarnPool is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;
  using Math for uint256;
  using EnumerableSet for EnumerableSet.AddressSet;

  /* STRUCTS */
  // withdrawal request
  // batchId: the batch id of the request
  // withdrawTime: the time of the request
  // amount: the amount of assets to withdraw
  struct WithdrawalRequest {
    uint256 batchId;
    uint256 withdrawTime;
    uint256 amount;
  }

  /* VARIABLES */
  // user => shares
  mapping(address => uint256) public balanceOf;
  // total shares
  uint256 public totalSupply;
  // last assets
  uint256 public userTotalAssets;
  // asset token address
  address public asset;
  // batch id => total withdraw amount
  mapping(uint256 => uint256) public totalWithdrawAmountInBatch;
  // User's address => WithdrawalRequest[]
  mapping(address => WithdrawalRequest[]) private userWithdrawalRequests;
  // The amount received but not claimable yet
  uint256 public withdrawQuota;
  // withdraw fee receiver
  address public feeReceiver;
  // withdraw fee rate
  uint256 public withdrawFeeRate;
  // period start time
  uint256 public periodStart;
  // reward of the current period
  uint256 public periodRewards;
  // last epoch day
  uint256 public lastDay;
  // current batch id
  uint256 public currentBatchId;
  // last confirmed batch id
  uint256 public confirmedBatchId;
  // name of the pool
  string public name;
  // symbol of the pool
  string public symbol;
  // adapter address
  address public adapter;
  // deposit whitelist
  EnumerableSet.AddressSet private whiteList;

  /* constants */
  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant PAUSER = keccak256("PAUSER"); // pauser role
  uint256 public constant PRECISION = 1 ether; // precision
  uint256 constant REWARD_DURATION = 1 weeks; // reward duration is 1 week

  /* EVENTS */
  event Transfer(address indexed from, address indexed to, uint256 value);
  event RequestWithdraw(
    address owner,
    address receiver,
    uint256 batchId,
    uint256 shares,
    uint256 amount,
    uint256 feeShares
  );
  event FinishWithdraw(uint256 epoch, uint256 amount);
  event ClaimWithdrawal(address user, uint256 idx, uint256 amount);
  event Deposit(address indexed user, uint256 amount);
  event NotifyInterest(uint256 interest);
  event SetFeeReceiver(address feeReceiver);
  event SetWithdrawFeeRate(uint256 withdrawFeeRate);
  event EmergencyWithdraw(address token, uint256 amount);

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  /**
   * @dev Initialize the contract
   * @param _admin The address of the admin role
   * @param _manager The address of the manager role
   * @param _pauser The address of the pauser role
   * @param _asset The address of the asset token
   * @param _name The name of the pool
   * @param _symbol The symbol of the pool
   * @param _adapter The address of the adapter
   */
  function initialize(
    address _admin,
    address _manager,
    address _pauser,
    address _asset,
    string memory _name,
    string memory _symbol,
    address _adapter
  ) public initializer {
    require(_admin != address(0), "admin address is zero");
    require(_manager != address(0), "manager address is zero");
    require(_pauser != address(0), "pauser address is zero");
    require(_asset != address(0), "asset address is zero");
    require(bytes(_name).length > 0, "name is empty");
    require(bytes(_symbol).length > 0, "symbol is empty");
    require(_adapter != address(0), "adapter address is zero");

    // initialize inherited contracts
    __AccessControl_init();
    __Pausable_init();
    __ReentrancyGuard_init();

    // setup roles
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);

    // setup variables
    asset = _asset;
    name = _name;
    symbol = _symbol;
    adapter = _adapter;
  }

  /* EXTERNAL FUNCTIONS */
  /**
   * @dev deposit funds to the pool
   * @param amount The amount of assets to deposit
   * @param shares The amount of shares to mint
   * @param receiver The address of the receiver
   */
  function deposit(uint256 amount, uint256 shares, address receiver) external whenNotPaused nonReentrant {
    require(amount > 0 || shares > 0, "amount and shares is zero");
    require(receiver != address(0), "receiver is zero address");
    require(isInWhiteList(receiver), "receiver not in whitelist");

    // calculate shares or amount
    if (amount > 0) {
      shares = convertToShares(amount);
    } else {
      amount = convertToAssets(shares);
    }
    // mint shares to user
    _mint(receiver, shares);
    userTotalAssets += amount;
    // transfer asset from user
    IERC20(asset).safeTransferFrom(msg.sender, adapter, amount);

    emit Deposit(receiver, amount);
  }

  /**
   * @dev request withdraw funds from the pool
   * @param amount The amount of assets to withdraw
   * @param shares The amount of shares to burn
   * @param receiver The address of the receiver
   */
  function requestWithdraw(uint256 amount, uint256 shares, address receiver) external whenNotPaused nonReentrant {
    require(amount > 0 || shares > 0, "amount and shares is zero");
    require(receiver != address(0), "receiver is zero address");

    // calculate shares or amount
    if (amount > 0) {
      shares = convertToShares(amount);
    } else {
      amount = convertToAssets(shares);
    }

    require(balanceOf[msg.sender] >= shares, "insufficient shares");

    uint256 feeShares;
    // charge withdraw fee
    if (withdrawFeeRate > 0 && feeReceiver != address(0)) {
      // feeShares =  shares * withdrawFeeRate / PRECISION
      feeShares = shares.mulDiv(withdrawFeeRate, PRECISION);
      if (feeShares > 0) {
        // transfer fee shares to feeReceiver
        _transfer(msg.sender, feeReceiver, feeShares);

        shares -= feeShares;
        amount -= convertToAssets(feeShares);
      }
    }

    // burn shares from user
    _burn(msg.sender, shares);

    // if new day, increase batch id
    // if currentBatchId == confirmedBatchId, increase batch id too
    uint256 day = block.timestamp / 1 days;
    if (day > lastDay) {
      lastDay = day;
      ++currentBatchId;
    } else if (currentBatchId == confirmedBatchId) {
      ++currentBatchId;
    }

    // add withdraw request to user
    userWithdrawalRequests[receiver].push(
      WithdrawalRequest({ batchId: currentBatchId, amount: amount, withdrawTime: block.timestamp })
    );

    // update total withdraw amount in batch
    totalWithdrawAmountInBatch[currentBatchId] += amount;
    // update user total assets
    userTotalAssets -= amount;

    emit RequestWithdraw(msg.sender, receiver, currentBatchId, shares, amount, feeShares);
  }

  /**
   * @dev finish withdraw funds from the pool
   * @param amount The amount of assets to finish withdraw
   */
  function finishWithdraw(uint256 amount) external {
    require(msg.sender == adapter, "only adapter can call");
    require(amount > 0, "amount is zero");

    // update withdraw quota
    withdrawQuota += amount;

    // cover withdraw requests in batch
    for (uint256 i = confirmedBatchId + 1; i <= currentBatchId; i++) {
      uint256 withdrawAmount = totalWithdrawAmountInBatch[i];
      // if withdraw amount cannot be covered, break
      if (withdrawAmount > withdrawQuota) {
        break;
      }
      // cover withdraw requests in batch
      confirmedBatchId = i;
      withdrawQuota -= withdrawAmount;
      emit FinishWithdraw(confirmedBatchId, withdrawAmount);
    }

    // transfer asset from adapter
    IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
  }

  /**
   * @dev claim withdraw funds from the pool
   * @param user The address of the user
   * @param idx The index of the withdraw request
   */
  function claimWithdraw(address user, uint256 idx) external whenNotPaused nonReentrant {
    WithdrawalRequest[] storage userRequests = userWithdrawalRequests[user];

    // check index
    require(idx < userRequests.length, "Invalid index");
    WithdrawalRequest memory withdrawRequest = userRequests[idx];

    // check if the request can be claimed
    require(withdrawRequest.batchId <= confirmedBatchId, "Not able to claim yet");

    // move the last request to the current index
    userRequests[idx] = userRequests[userRequests.length - 1];
    userRequests.pop();

    // transfer asset to user
    IERC20(asset).safeTransfer(user, withdrawRequest.amount);

    emit ClaimWithdrawal(user, idx, withdrawRequest.amount);
  }

  /**
   * @dev notify interest to the pool
   * @param amount The amount of interest
   */
  function notifyInterest(uint256 amount) external {
    require(msg.sender == adapter, "only adapter can call");

    // update user total assets
    userTotalAssets = totalAssets();

    // update period rewards and period start
    periodRewards = getUnvestAmount() + amount;
    periodStart = block.timestamp;

    emit NotifyInterest(amount);
  }

  /**
   * @dev get unvest amount
   * @return The amount of unvest
   */
  function getUnvestAmount() public view returns (uint256) {
    // if no rewards or period finished, return 0
    if (block.timestamp >= periodStart + REWARD_DURATION) {
      return 0;
    }

    // unvest = (periodFinish - block.timestamp) * periodRewards / REWARD_DURATION
    uint256 duration = periodStart + REWARD_DURATION - block.timestamp;
    return duration.mulDiv(periodRewards, REWARD_DURATION);
  }

  /**
   * @dev convert assets to shares
   * @param assets The amount of assets to convert
   * @return The amount of shares
   */
  function convertToShares(uint256 assets) public view returns (uint256) {
    // if no shares or no assets, return assets
    if (totalSupply == 0 || totalAssets() == 0) {
      return assets;
    }
    // shares = assets * totalSupply / totalAssets
    return assets.mulDiv(totalSupply, totalAssets());
  }

  /**
   * @dev convert shares to assets
   * @param shares The amount of shares to convert
   * @return The amount of assets
   */
  function convertToAssets(uint256 shares) public view returns (uint256) {
    // if no shares or no assets, return shares
    if (totalSupply == 0 || totalAssets() == 0) {
      return shares;
    }
    // assets = shares * totalAssets / totalSupply
    return shares.mulDiv(totalAssets(), totalSupply);
  }

  /**
   * @dev get total assets of the pool
   * @return The amount of total assets
   */
  function totalAssets() public view returns (uint256) {
    // total assets = userTotalAssets + periodRewards - getUnvestAmount()
    return userTotalAssets + periodRewards - getUnvestAmount();
  }

  /**
   * @dev get claimable request indexes of a user
   * @param user The address of the user
   * @return The indexes of the claimable requests
   */
  function getClaimableRequestIndexes(address user) external view returns (uint256[] memory) {
    WithdrawalRequest[] storage userRequests = userWithdrawalRequests[user];
    uint256 count = 0;
    // count claimable requests
    for (uint256 i = 0; i < userRequests.length; i++) {
      if (userRequests[i].batchId <= confirmedBatchId) {
        count++;
      }
    }

    uint256[] memory indexes = new uint256[](count);
    uint256 idx = 0;
    // get claimable request indexes
    for (uint256 i = 0; i < userRequests.length; i++) {
      if (userRequests[i].batchId <= confirmedBatchId) {
        indexes[idx] = i;
        idx++;
      }
    }
    return indexes;
  }

  function getUserWithdrawalRequests(address user) external view returns (WithdrawalRequest[] memory) {
    return userWithdrawalRequests[user];
  }

  /**
   * @dev check if a user is in the whitelist
   * @param user The address of the user
   * @return True if the user is in the whitelist, false otherwise
   */
  function isInWhiteList(address user) public view returns (bool) {
    return whiteList.length() == 0 || whiteList.contains(user);
  }

  /**
   * @dev get the whitelist
   * @return The addresses in the whitelist
   */
  function getWhiteList() external view returns (address[] memory) {
    return whiteList.values();
  }

  /* ADMIN FUNCTIONS */
  /**
   * @dev set withdraw fee rate
   * @param _withdrawFeeRate The withdraw fee rate
   */
  function setWithdrawFeeRate(uint256 _withdrawFeeRate) external onlyRole(MANAGER) {
    require(_withdrawFeeRate <= PRECISION, "withdraw fee rate too high");
    require(withdrawFeeRate != _withdrawFeeRate, "same withdraw fee rate");
    withdrawFeeRate = _withdrawFeeRate;

    emit SetWithdrawFeeRate(_withdrawFeeRate);
  }

  /**
   * @dev set fee receiver
   * @param _feeReceiver The address of the fee receiver
   */
  function setFeeReceiver(address _feeReceiver) external onlyRole(MANAGER) {
    require(_feeReceiver != address(0), "fee receiver is zero address");
    require(feeReceiver != _feeReceiver, "same fee receiver");
    feeReceiver = _feeReceiver;

    emit SetFeeReceiver(_feeReceiver);
  }

  /**
   * @dev set whitelist status of a user
   * @param user The address of the user
   * @param ok True to add to whitelist, false to remove from whitelist
   */
  function setWhiteList(address user, bool ok) external onlyRole(MANAGER) {
    require(user != address(0), "user is zero address");
    require(whiteList.contains(user) != ok, "same status");
    if (ok) {
      whiteList.add(user);
    } else {
      whiteList.remove(user);
    }
  }

  /**
   * @dev allows manager to withdraw reward tokens for emergency or recover any other mistaken ERC20 tokens.
   * @param token ERC20 token address
   * @param amount token amount
   */
  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    IERC20(token).safeTransfer(msg.sender, amount);
    emit EmergencyWithdraw(token, amount);
  }

  /* INTERNAL FUNCTIONS */
  function _mint(address account, uint256 amount) internal {
    require(account != address(0), "mint to the zero address");

    balanceOf[account] += amount;
    totalSupply += amount;

    emit Transfer(address(0), account, amount);
  }

  function _burn(address account, uint256 amount) internal {
    require(account != address(0), "burn from the zero address");
    require(balanceOf[account] >= amount, "burn amount exceeds balance");

    balanceOf[account] -= amount;
    totalSupply -= amount;

    emit Transfer(account, address(0), amount);
  }

  function _transfer(address from, address to, uint256 amount) internal {
    require(from != address(0), "transfer from the zero address");
    require(to != address(0), "transfer to the zero address");
    require(balanceOf[from] >= amount, "transfer amount exceeds balance");

    balanceOf[from] -= amount;
    balanceOf[to] += amount;

    emit Transfer(from, to, amount);
  }

  /**
   * @dev pause contract
   */
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  /**
   * @dev unpause contract
   */
  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
