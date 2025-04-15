// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./library/FullMath.sol";
import { NonTransferableLpERC20 } from "./token/NonTransferableLpERC20.sol";
import { ILisBNB } from "./interface/ILisBNB.sol";
import { IStakeManager } from "./interface/IStakeManager.sol";
import { ILisBnbMinter } from "./interface/ILisBnbMinter.sol";

/**
 * @title LisBnbMinter Contract
 * @dev The `LisBnbMinter` contract is a core component of the LisBNB protocol,
 *      facilitating the minting and management of LisBNB, a liquid staking token representing staked BNB.
 *      It enables users to deposit BNB or slisBNB to receive LisBNB, request withdrawals of their staked BNB,
 *      and claim their withdrawals after a specified delay.
 *      The contract interacts with a stake manager to handle the staking and unstaking of BNB to validators.
 *
 * ### Key Features:
 * - Deposits:
 *   Users can deposit BNB or slisBNB to mint LisBNB.
 *   Deposits are staked via the stake manager,
 *   and clisBNB is minted to MPC wallets to participant campaigns that can earn rewards.
 *
 * - Withdrawals:
 *   Users can request to withdraw their staked BNB by burning LisBNB.
 *   Withdrawals are processed in batches to optimize gas costs and comply with the stake manager's mechanics.
 *   Users can claim their BNB once the batch is confirmed.
 *
 * - Rewards Compounding and Yield:
 *   The contract compounds both validator staking rewards and
 *   additional campaign rewards (e.g., from LaunchPool, Hodler, or MegaDrop).
 *   A commission is taken on these rewards, and the remaining amount is reinvested to increase the total staked BNB.
 *
 * - Reserve Management: The contract maintains a reserve of LisBNB,
 *   which can be deposited and withdrawn by the operator to ensure liquidity or handle emergencies.
 *
 * ### Usage:
 * - Users: Interact with the contract to deposit BNB or slisBNB, request withdrawals, and claim their withdrawn BNB.
 * - Bots and Operators: Manage batch withdrawals, claim batch withdrawals, deposit rewards, and compound rewards.
 * - Admins & Manager: Manage MPC wallets, set key addresses (redirect address, revenue pool),
 *   adjust the fee rate, and pause/unpause the contract.
 */
contract LisBnbMinter is
  ILisBnbMinter,
  Initializable,
  AccessControlUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  UUPSUpgradeable
{
  using SafeERC20 for IERC20;
  using SafeERC20 for ILisBNB;
  using SafeERC20 for NonTransferableLpERC20;
  // pause role
  bytes32 public constant PAUSER = keccak256("PAUSER");
  // manager role
  bytes32 public constant MANAGER = keccak256("MANAGER");
  // bot role
  bytes32 public constant BOT = keccak256("BOT");
  // Operator role
  bytes32 public constant OPERATOR = keccak256("OPERATOR");
  // denominator
  uint256 public constant DENOMINATOR = 10000;
  // the buffer that compensates the precision loss when withdraw: 100 wei
  uint256 public constant BUFFER = 100;
  // Number of days to split the rewards
  uint256 public constant REWARD_SPLIT_DAYS = 21;
  // commission fee rate when compounding rewards (DENOMINATOR = 10000)
  uint256 public feeRate;
  // accrued commission fee (Manager can withdraw it any time)
  uint256 public feeAccrued;
  // address of BNB redirect to if someone sends BNB to this contract
  address public redirectAddress;
  // revenue pool address
  address public revenuePool;

  // LisBNB
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  ILisBNB public immutable lisBnb;
  // clisBNB
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  NonTransferableLpERC20 public immutable clisBnb;
  // slisBNB
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IERC20 public immutable slisBnb;
  // stake manager
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IStakeManager public immutable stakeManager;

  // total BNB deposited
  uint256 public totalTokens;
  // total reserved LisBNB
  // @dev to prevent an extreme case of withdrawal failure
  //      suggested value: larger than 7 * 100 wei
  uint256 public totalReserved;
  // BNB waiting to withdraw from stakeManager
  uint256 public withdrawableBnb;
  // BNB claimed from stakeManager (can be claimed by user immediately)
  uint256 public claimableBnb;

  // withdrawal request ID
  uint256 public reqId;
  // next batch withdraw request ID
  uint256 public batchId;
  // batch withdraw request ID that was able to be withdrawn
  uint256 public confirmedBatchId;
  // last batch withdrawal request time
  uint256 public lastBatchWithdrawTime;
  // batch ID => amount of BNB withdrawn
  mapping(uint256 batchId => uint256 withdrawnBnbAmount) public batchWithdrawnBnbAmount;
  // user requests
  mapping(address => UserRequest[]) public userRequests;
  // mpc wallets
  MPCWallet[] public mpcWallets;
  // Reward Compound Status
  RewardCompound public rewardCompoundStatus;

  /// @custom:oz-upgrades-unsafe-allow constructor
  /**
   * @dev Constructor
   * @param _lisBnb address of the LisBNB contract
   * @param _clisBnb address of the clisBNB contract
   * @param _slisBnb address of the slisBNB contract
   * @param _stakeManager address of the stake manager contract
   */
  constructor(address _lisBnb, address _clisBnb, address _slisBnb, address _stakeManager) {
    // no zero-address is allowed
    require(
      _lisBnb != address(0) && _clisBnb != address(0) && _slisBnb != address(0) && _stakeManager != address(0),
      "zero address provided"
    );
    // prevent re-initialization of the impl. contract
    _disableInitializers();
    // init tokens
    lisBnb = ILisBNB(_lisBnb);
    clisBnb = NonTransferableLpERC20(_clisBnb);
    slisBnb = IERC20(_slisBnb);
    stakeManager = IStakeManager(_stakeManager);
  }

  /**
   * @dev contract initializer
   * @param _admin address of the admin
   * @param _manager address of the manager
   * @param _pauser address of the pauser
   * @param _bot address of the bot
   * @param _operator address of the operator
   */
  function initialize(
    address _admin,
    address _manager,
    address _pauser,
    address _bot,
    address _operator,
    address _redirectAddress,
    address _revenuePool
  ) external initializer {
    // no zero-address is allowed
    require(
      _admin != address(0) &&
        _manager != address(0) &&
        _pauser != address(0) &&
        _bot != address(0) &&
        _operator != address(0),
      "zero address provided"
    );
    // init underlying contracts
    __Pausable_init();
    __ReentrancyGuard_init();
    __AccessControl_init();
    __UUPSUpgradeable_init();

    // grant key roles
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);
    _grantRole(OPERATOR, _operator);
    _grantRole(BOT, _bot);

    // set initial values
    feeRate = 0;
    redirectAddress = _redirectAddress;
    revenuePool = _revenuePool;

    slisBnb.safeIncreaseAllowance(address(stakeManager), type(uint256).max);
  }

  ///// ------------------------------ User functions ------------------------------ /////

  /**
   * @dev Deposit BNB to the contract and mint LisBNB
   */
  function deposit() external payable whenNotPaused nonReentrant {
    require(msg.value > 0, "Deposit amount must be greater than 0");
    // deposit to stake manager
    stakeManager.deposit{ value: msg.value }();
    // deposit and stakes BNB
    _deposit(msg.sender, msg.value);
  }

  /**
   * @dev Deposit slisBNB to the contract and mint LisBNB
   * @param slisBnbAmount - amount of slisBNB to deposit
   */
  function deposit(uint256 slisBnbAmount) external whenNotPaused nonReentrant {
    require(slisBnbAmount > 0, "Deposit amount must be greater than 0");
    // transfer slisBNB to this contract
    slisBnb.safeTransferFrom(msg.sender, address(this), slisBnbAmount);
    // calculate how much BNB to deposit
    uint256 amount = stakeManager.convertSnBnbToBnb(slisBnbAmount);
    // deposit without stakes BNB
    _deposit(msg.sender, amount);
  }

  /**
   * @dev Request withdrawal of BNB
   * @param amount - amount of LisBNB to withdraw
   */
  function requestWithdrawal(uint256 amount) external whenNotPaused nonReentrant {
    require(amount > 0, "Withdraw amount must be greater than 0");
    // transfer lisBnb to this contract
    lisBnb.safeTransferFrom(msg.sender, address(this), amount);
    // process withdrawal
    _requestWithdrawal(msg.sender, amount);
  }

  /**
   * @dev Claim withdrawal of BNB
   * @param idx - index of the withdrawal request
   */
  function claimWithdrawal(uint256 idx) external whenNotPaused nonReentrant {
    _claimWithdrawal(msg.sender, idx);
  }

  ///// ------------------------------ View functions ------------------------------ /////

  /**
   * @dev get conversion rate of LisBNB to BNB
   * @return uint256
   */
  function convertToBnb(uint256 lisBnbAmt) public view returns (uint256) {
    uint256 totalSupply = lisBnb.totalSupply();
    // Refer to ERC4626
    // https://docs.openzeppelin.com/contracts/4.x/erc4626#defending_with_a_virtual_offset
    return FullMath.mulDiv(lisBnbAmt, totalTokens + 1, totalSupply + 1);
  }

  /**
   * @dev Get conversion rate of BNB to LisBNB
   * @param tokens - amount of BNB
   */
  function convertToLisBnb(uint256 tokens) public view returns (uint256) {
    uint256 totalSupply = lisBnb.totalSupply();
    // refer to ERC4626's standard
    return FullMath.mulDiv(tokens, totalSupply + 1, totalTokens + 1);
  }

  ///// ------------------------------ Operator/Bot functions ------------------------------ /////

  /**
   * @dev Request batch withdrawal of BNB
   *      The amount of BNB to withdraw is the total amount of BNB requested by users
   */
  function batchRequestWithdrawal() external whenNotPaused nonReentrant onlyRole(BOT) {
    require(block.timestamp - lastBatchWithdrawTime >= 1 hours, "Allowed once per hour");
    require(withdrawableBnb > 0, "No BNB to withdraw");
    // withdraw amt < claimable amt, no need to request withdrawal
    if (withdrawableBnb <= claimableBnb) {
      // latest batch available immediately
      ++batchId;
      ++confirmedBatchId;
      emit BatchWithdrawalClaimed(batchId, withdrawableBnb);
      return;
    }
    // record withdrawableBnb
    uint256 withdrawableBnb_ = withdrawableBnb;
    // save if for later use at batchClaimWithdrawal()
    batchWithdrawnBnbAmount[confirmedBatchId] = withdrawableBnb_;
    // reset withdrawableBnb
    withdrawableBnb = 0;
    // convert withdrawableBnb to slisBNB Amount
    uint256 slisBnbAmount = stakeManager.convertBnbToSnBnb(withdrawableBnb + BUFFER - claimableBnb);
    // request batch withdrawal
    stakeManager.requestWithdraw(slisBnbAmount);
    // label batch ID (starts from 1)
    ++batchId;
    // emit event
    emit BatchWithdrawalRequested(batchId, withdrawableBnb_, slisBnbAmount);
  }

  /**
   * @dev Claim batch withdrawal of BNB
   * @dev Process and claim batch in order, when the earliest batch is claimable,
   *      increase the confirmedBatchId,
   *      UserRequest is able to claim when it's batchId less than or equals to it
   */
  function batchClaimWithdrawal() external whenNotPaused nonReentrant onlyRole(BOT) {
    // get all withdrawal requests
    IStakeManager.WithdrawalRequest[] memory requests = stakeManager.getUserWithdrawalRequests(address(this));
    require(requests.length > 0, "No requests to claim");
    uint256 _uuid = type(uint256).max;
    // find the smallest UUID
    for (uint256 i = 0; i < requests.length; ++i) {
      if (requests[i].uuid < _uuid) {
        _uuid = requests[i].uuid;
      }
    }
    // get idx of uuid
    uint256 idx = stakeManager.requestIndexMap(_uuid);
    // check if the request is claimable
    (bool isClaimable, uint256 amount) = stakeManager.getUserRequestStatus(address(this), idx);
    // check if the request is claimable
    if (isClaimable) {
      // withdraw BNB from StakeManager
      stakeManager.claimWithdraw(idx);
      // cache confirmedBatchId
      uint256 _confirmedBatchId = confirmedBatchId;
      // label the previous batch's requests can be claimed
      ++confirmedBatchId;
      // update claimableBnb += actual arrived amount - claimed amount
      claimableBnb += amount - batchWithdrawnBnbAmount[confirmedBatchId];
      // emit event
      emit BatchWithdrawalClaimed(_confirmedBatchId, amount);
    }
  }

  /**
   * @dev Deposit rewards(BNB) to the contract and mint LisBNB
   *      LaunchPool/Hodler/MegaDrop rewards etc.
   */
  function depositRewards() external payable whenNotPaused nonReentrant onlyRole(OPERATOR) {
    require(msg.value > 0, "Deposit amount must be greater than 0");
    uint256 amount = msg.value;
    // transfer BNB to the contract
    totalTokens += amount;
    // calculate how must LisBNB to mint
    uint256 lisBnbAmt = convertToLisBnb(msg.value);
    // mint LisBNB
    lisBnb.mint(address(this), lisBnbAmt);
    // mint clisBnb
    _mintClisBnbToMPCs(amount);

    // update reward compound status
    uint256 newRemainingLisBnb = rewardCompoundStatus.remainingLisBnb + lisBnbAmt;
    // split new total rewards into a certain number of days
    uint256 newDailyLisBnb = newRemainingLisBnb / REWARD_SPLIT_DAYS;
    require(newDailyLisBnb > 0, "Invalid Daily LisBnb");
    // update reward compound status
    rewardCompoundStatus.remainingLisBnb = newRemainingLisBnb;
    rewardCompoundStatus.dailyLisBnbAmt = newDailyLisBnb;

    // emit event
    emit RewardsDeposited(msg.sender, msg.value, lisBnbAmt);
  }

  /**
   * @dev Compound rewards
   *      1. Validator rewards
   *      2. LaunchPool/Hodler/MegaDrop rewards etc.
   */
  function compoundRewards() external whenNotPaused nonReentrant onlyRole(BOT) {
    // ----- [1] Validator rewards -----
    // get BNB value represented by contract slisBNB holding
    uint256 slisBnbBalance = slisBnb.balanceOf(address(this));
    uint256 totalDelegatedBnb = stakeManager.convertSnBnbToBnb(slisBnbBalance);
    // calculate profit of BNB staking
    uint256 stakingProfit = totalDelegatedBnb - withdrawableBnb - totalTokens;
    // node Rewards for commission
    uint256 bnbCut = FullMath.mulDiv(stakingProfit, feeRate, DENOMINATOR);
    // convert the cut to LisBnb
    uint256 lisBnbCut = convertToLisBnb(bnbCut);

    // total token increment
    totalTokens += stakingProfit;
    // mint LisBnb to this contract
    lisBnb.mint(address(this), lisBnbCut);
    // mint to mpcWallets
    _mintClisBnbToMPCs(stakingProfit);

    // ----- [2] LaunchPool/Hodler/MegaDrop rewards etc. -----
    uint256 campaignRewardsInLisBnb = _compoundCampaignRewards();

    // commission cut of [1] + [2]
    uint256 totalCommissionInLisBnb = lisBnbCut + campaignRewardsInLisBnb;
    // accrue fee
    lisBnb.safeTransfer(revenuePool, totalCommissionInLisBnb);

    // emit event
    emit RewardsCompounded(totalCommissionInLisBnb);
  }
  ///// ------------------------------ LisBNB Reserve functions  ------------------------------ /////

  /**
   * @dev Deposit BNB to the contract and mint Reserved LisBNB
   */
  function depositReserve() external payable whenNotPaused nonReentrant onlyRole(OPERATOR) {
    require(msg.value > 0, "Deposit amount must be greater than 0");
    // deposit to stake manager
    stakeManager.deposit{ value: msg.value }();
    // deposit BNB
    uint256 lisBnbAmt = _deposit(address(this), msg.value);
    // transfer BNB to the contract
    totalReserved += lisBnbAmt;
    // emit event
    emit ReserveDeposited(msg.sender, msg.value, lisBnbAmt);
  }

  /**
   * @dev Request withdrawal of BNB from Reserved LisBNB
   * @param amount - amount of LisBNB to withdraw
   */
  function requestWithdrawReserve(uint256 amount) external whenNotPaused nonReentrant onlyRole(OPERATOR) {
    require(amount > 0, "Withdraw amount must be greater than 0");
    // transfer BNB to the contract
    totalReserved -= amount;
    // request withdrawal
    uint256 bnbAmount = _requestWithdrawal(address(this), amount);
    // emit event
    emit ReserveWithdrawalRequested(msg.sender, bnbAmount, amount);
  }

  /**
   * @dev Claim withdrawal of BNB from the withdrawn Reserved LisBNB
   * @param idx - index of the withdrawal request
   */
  function claimWithdrawReserve(uint256 idx) external whenNotPaused nonReentrant onlyRole(OPERATOR) {
    uint256 claimed = _claimWithdrawal(address(this), idx);
    emit ReserveWithdrawalClaimed(msg.sender, claimed);
  }

  ///// ------------------------------ Internal functions ------------------------------ /////

  /**
   * @dev Deposit BNB and mint LisBNB to the sender.
   * @dev 1. Minter mints clisBNB to MPC wallets (BNB:clisBNB = 1:1)
   *      2. user gets LisBNB
   * @param amount - amount of BNB to deposit
   */
  function _deposit(address user, uint256 amount) internal returns (uint256) {
    // record increment of totalTokens
    totalTokens += amount;
    // get conversion rate
    uint256 lisBnbAmt = convertToLisBnb(amount);
    // mint LisBNB
    lisBnb.mint(user, lisBnbAmt);
    // mint clisBNB to MPC wallets
    _mintClisBnbToMPCs(amount);
    // emit event
    emit Deposited(user, amount, lisBnbAmt);

    return lisBnbAmt;
  }

  /**
   * @dev Request withdrawal of BNB
   * @param user - address of the user
   * @param amount - amount of LisBNB to withdraw
   */
  function _requestWithdrawal(address user, uint256 amount) internal returns (uint256) {
    // get BNB amount represented by the lisBnb
    uint256 bnbAmount = convertToBnb(amount);
    // get slisBNB amount represented by the bnbAmount
    uint256 slisBnbAmount = stakeManager.convertBnbToSnBnb(bnbAmount);

    // burn lisBnb
    lisBnb.burn(address(this), amount);
    // deduct totalTokens
    totalTokens -= bnbAmount;
    // burn clisBNB
    _burnClisBnbFromMPCs(bnbAmount);

    // request withdrawal
    stakeManager.requestWithdraw(slisBnbAmount);
    // withdrawableBnb increment
    withdrawableBnb += bnbAmount;
    // request ID increment
    ++reqId;
    // save user withdrawal request
    userRequests[user].push(
      UserRequest({ id: reqId, batchId: batchId, bnbAmount: bnbAmount, lisBnbAmount: amount, time: block.timestamp })
    );
    // emit event
    emit WithdrawalRequested(user, bnbAmount, amount);

    return bnbAmount;
  }

  /**
   * @dev Claim withdrawal of BNB
   * @param user - address of the user
   * @param idx - index of the withdrawal request
   */
  function _claimWithdrawal(address user, uint256 idx) internal returns (uint256) {
    require(idx < userRequests[user].length, "Invalid index");
    // get user requests
    UserRequest[] storage requestQueue = userRequests[user];
    // check if the request is already claimed
    require(requestQueue[idx].batchId < confirmedBatchId, "Batch not able to claim yet");
    // get user request
    UserRequest storage request = requestQueue[idx];
    // get the user request
    uint256 amountToClaim = request.bnbAmount;
    // move request to the end and pop it out
    requestQueue[idx] = requestQueue[requestQueue.length - 1];
    requestQueue.pop();
    // send BNB to user
    // @dev if caller is the contract itself, send to msg.sender
    Address.sendValue(payable(user == address(this) ? msg.sender : user), amountToClaim);
    // emit event
    emit WithdrawalClaimed(user, amountToClaim);

    return amountToClaim;
  }

  /**
   * @dev Mint clisBNB to MPC wallets
   *      mint the clisBNB as the amount of totalToken increment
   *      first mint, last burn
   * @param clisBnbAmt - amount of clisBNB to mint
   */
  function _mintClisBnbToMPCs(uint256 clisBnbAmt) internal {
    uint256 leftToMint = clisBnbAmt;
    // loop through the MPC wallets
    for (uint256 i = 0; i < mpcWallets.length; ++i) {
      // mint completed
      if (leftToMint == 0) break;
      // get the current wallet
      MPCWallet storage wallet = mpcWallets[i];
      // get clisBNB balance
      uint256 balance = wallet.balance;
      // balance not reached the cap yet
      if (balance <= wallet.cap) {
        uint256 toMint = balance + leftToMint > wallet.cap ? wallet.cap - balance : leftToMint;
        // mint clisBNB to the wallet
        clisBnb.mint(wallet.walletAddress, toMint);
        // add up balance
        wallet.balance += toMint;
        // deduct leftToMint
        leftToMint -= toMint;
      }
    }
  }

  /**
   * @dev Burn clisBNB from MPC wallets
   *      burn the clisBNB as the amount of totalToken decrement
   *      burn from the last MPC wallet
   * @param clisBnbAmt - amount of clisBNB to burn
   */
  function _burnClisBnbFromMPCs(uint256 clisBnbAmt) internal {
    uint256 leftToBurn = clisBnbAmt;
    // loop through the MPC wallets
    for (uint256 i = mpcWallets.length - 1; i == 0; --i) {
      // burn completed
      if (leftToBurn == 0) break;
      // get the current wallet
      MPCWallet storage wallet = mpcWallets[i];
      // get clisBNB balance
      uint256 balance = wallet.balance;
      // balance not reached the cap yet
      if (balance > 0) {
        uint256 toBurn = balance < leftToBurn ? balance : leftToBurn;
        // burn clisBNB from MPC
        clisBnb.burn(wallet.walletAddress, toBurn);
        // deduct balance
        wallet.balance -= toBurn;
        // deduct leftToMint
        leftToBurn -= toBurn;
      }
    }
  }

  /**
   * @dev Compound campaign rewards
   * @return commissionAmount - amount of commission in LisBnb to be accrued
   */
  function _compoundCampaignRewards() internal returns (uint256 commissionAmount) {
    // nothing to compound
    if (rewardCompoundStatus.remainingLisBnb == 0) return 0;
    // compound once a day
    // current day 00:00 < last compounded days 00:00
    if (block.timestamp / 1 days < (rewardCompoundStatus.lastCompoundedTime / 1 days + 1)) return 0;
    // get deducted LisBnb for commission
    commissionAmount = FullMath.mulDiv(rewardCompoundStatus.dailyLisBnbAmt, feeRate, DENOMINATOR);
    // get the amount of slisBnb to be burned
    uint256 burnAmount = rewardCompoundStatus.dailyLisBnbAmt - commissionAmount;
    // the last day of compounding
    if (burnAmount > rewardCompoundStatus.remainingLisBnb) {
      burnAmount = rewardCompoundStatus.remainingLisBnb;
      rewardCompoundStatus.remainingLisBnb = 0;
      rewardCompoundStatus.dailyLisBnbAmt = 0;
    } else {
      rewardCompoundStatus.remainingLisBnb -= burnAmount;
    }
    // update last compounded time
    rewardCompoundStatus.lastCompoundedTime = block.timestamp;
    // burn LisBnb
    lisBnb.burn(address(this), burnAmount);

    return commissionAmount;
  }

  ///// ------------------------------ Admin functions ------------------------------ /////

  /**
   * @dev Set the address of the revenue pool
   * @param _revenuePool - new address of the revenue pool
   */
  function setRevenuePool(address _revenuePool) external onlyRole(MANAGER) {
    require(_revenuePool != address(0), "zero address provided");
    require(_revenuePool != revenuePool, "Revenue pool is the same");
    address oldRevenuePool = revenuePool;
    revenuePool = _revenuePool;
    emit RevenuePoolChanged(oldRevenuePool, _revenuePool);
  }

  /**
   * @dev Withdraw accrued fee in LisBNB to the recipient
   * @param recipient - address of the recipient
   */
  function withdrawAccruedFee(address recipient) external nonReentrant onlyRole(MANAGER) {
    require(feeAccrued > 0, "No fee to withdraw");
    // default recipient is the sender
    recipient = recipient == address(0) ? msg.sender : recipient;
    // get the fee amount
    uint256 fee = feeAccrued;
    // reset fee
    feeAccrued = 0;
    // transfer fee to the recipient
    lisBnb.safeTransfer(recipient, fee);
    // emit event
    emit FeeWithdrawn(recipient, fee);
  }

  /**
   * @dev Set the cap of the MPC wallet
   * @param idx - index of the MPC wallet
   * @param cap - new cap of the MPC wallet
   */
  function setMpcWalletCap(uint256 idx, uint256 cap) external onlyRole(MANAGER) {
    require(idx < mpcWallets.length, "Invalid index");
    require(cap > 0 && cap != mpcWallets[idx].cap, "Invalid cap");
    // get the current wallet
    MPCWallet storage wallet = mpcWallets[idx];
    // save old cap
    uint256 oldCap = wallet.cap;
    // set the cap
    wallet.cap = cap;
    // if cap less than the balance
    // we need to burn the difference, and mint to other MPCs
    if (cap < wallet.balance) {
      uint256 toBurn = wallet.balance - cap;
      // burn clisBNB from MPC
      clisBnb.burn(wallet.walletAddress, toBurn);
      // deduct balance
      wallet.balance -= toBurn;
      // mint clisBNB to the other MPCs
      _mintClisBnbToMPCs(toBurn);
    }
    // emit event
    emit MpcWalletCapChanged(wallet.walletAddress, oldCap, cap);
  }

  /**
   * @dev Remove MPC wallet
   * @param idx - index of the MPC wallet
   */
  function removeMPCWallet(uint256 idx) external onlyRole(MANAGER) {
    require(idx < mpcWallets.length, "Invalid index");
    // get the current wallet
    MPCWallet storage wallet = mpcWallets[idx];
    // cache address
    address walletAddress = wallet.walletAddress;
    // check if the balance is 0
    require(wallet.balance == 0, "Balance not zero");
    // remove the wallet
    mpcWallets[idx] = mpcWallets[mpcWallets.length - 1];
    mpcWallets.pop();
    // emit event
    emit MpcWalletRemoved(walletAddress);
  }

  /**
   * @dev Add MPC wallet
   * @param walletAddress - address of the MPC wallet
   * @param cap - cap of the MPC wallet
   */
  function addMPCWallet(address walletAddress, uint256 cap) external onlyRole(MANAGER) {
    require(walletAddress != address(0), "zero address provided");
    // check if the wallet already exists
    for (uint256 i = 0; i < mpcWallets.length; ++i) {
      require(mpcWallets[i].walletAddress != walletAddress, "Wallet already exists");
    }
    // add the wallet
    mpcWallets.push(MPCWallet(walletAddress, 0, cap));
    // emit event
    emit MpcWalletAdded(walletAddress, cap);
  }

  /**
   * @dev Set the address of the redirect address
   * @param newRedirectAddress - new redirect address
   */
  function setRedirectAddress(address newRedirectAddress) external onlyRole(MANAGER) {
    require(newRedirectAddress != address(0), "zero address provided");
    require(newRedirectAddress != redirectAddress, "Redirect address is the same");
    address oldRedirectAddress = redirectAddress;
    redirectAddress = newRedirectAddress;
    emit RedirectAddressChanged(oldRedirectAddress, newRedirectAddress);
  }

  /**
   * @dev Set the fee rate of reward's commission
   * @param newFeeRate - new fee rate
   */
  function setFeeRate(uint256 newFeeRate) external onlyRole(MANAGER) {
    require(newFeeRate <= DENOMINATOR, "Fee rate must be less than or equals 100%");
    uint256 oldFeeRate = feeRate;
    feeRate = newFeeRate;
    emit FeeRateChanged(oldFeeRate, newFeeRate);
  }

  /**
   * @dev Flips the pause state
   */
  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  /**
   * @dev pause the contract
   */
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  /**
   * @dev added onlyRole modifier restricts only the admin to call this function
   * @notice There is only one Admin and it is a TimeLock contract
   * @param newImplementation - address of the new implementation
   */
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  /**
   * @dev all fund transfer to redirectAddress if it's no coming from the StakeManager or RedirectAddress
   */
  receive() external payable {
    if (msg.sender != address(stakeManager) && msg.sender != redirectAddress) {
      Address.sendValue(payable(redirectAddress), msg.value);
    }
  }
}
