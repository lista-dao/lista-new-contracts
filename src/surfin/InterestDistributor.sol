// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { IInterestDistributor } from "./interface/IInterestDistributor.sol";

/**
 * @title InterestDistributor
 * @author Lista DAO
 * @notice Cumulative-Merkle interest distributor for the Surfin Credit Fund.
 *
 * Models lista-new-contracts/src/LendingRewardsDistributorV2.sol:
 *  - cumulative Merkle claims (the leaf carries the running total; the contract
 *    stores the already-claimed amount and only pays the delta);
 *  - a two-step, time-locked root update (setPendingMerkleRoot -> wait ->
 *    acceptMerkleRoot) so a bad root can be revoked before it goes live.
 *
 * Unlike the lending distributor, funds are not sent here directly: they live on
 * the SurfinAdapter, which tops this contract up via `notifyReward` (guarded by
 * FUNDER role) before publishing each weekly root. Users then claim their
 * cumulative interest directly from this contract.
 */
contract InterestDistributor is
  IInterestDistributor,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  UUPSUpgradeable
{
  using SafeERC20 for IERC20;

  /// @dev current merkle root
  bytes32 public merkleRoot;

  /// @dev the single interest token (USDT); leaves and payouts are denominated in it
  address public token;

  /// @dev userAddress => total claimed amount
  mapping(address => uint256) public claimed;

  /// @dev the next merkle root to be set
  bytes32 public pendingMerkleRoot;

  /// @dev last time pending merkle root was set
  uint256 public lastSetTime;

  /// @dev the waiting period before accepting the pending merkle root; 6 hours by default
  uint256 public waitingPeriod;

  /**
   * @dev earliest timestamp `pendingMerkleRoot` may be accepted at, frozen when the root
   *      is staged. 0 when nothing is pending.
   *
   *      Computing acceptance live as `lastSetTime + waitingPeriod` would let a
   *      `changeWaitingPeriod` landing mid-flight retroactively move the deadline of a
   *      root already under review — shortening the window the delay exists to provide,
   *      or pushing an urgent root days out by accident. Each root instead carries the
   *      period it was staged under, so `changeWaitingPeriod` only affects roots staged
   *      after it.
   *
   *      Declared last so no existing storage slot shifts; one slot is taken from __gap.
   */
  uint256 public pendingActivationTime;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant PAUSER = keccak256("PAUSER");
  bytes32 public constant FUNDER = keccak256("FUNDER");

  event Claimed(address indexed account, uint256 amount, uint256 totalAmount);
  event SkipClaim(address indexed account, uint256 totalAmount);
  event RewardFunded(address indexed funder, uint256 amount);
  event SetPendingMerkleRoot(bytes32 merkleRoot, uint256 lastSetTime, uint256 activationTime);
  event AcceptMerkleRoot(bytes32 merkleRoot, uint256 acceptedTime);
  event WaitingPeriodUpdated(uint256 waitingPeriod);
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
   * @param _funder Address allowed to fund interest (the SurfinAdapter)
   * @param _token Address of the single interest token (USDT)
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _pauser,
    address _funder,
    address _token
  ) external initializer {
    require(_admin != address(0), "Invalid admin address");
    require(_manager != address(0), "Invalid manager address");
    require(_bot != address(0), "Invalid bot address");
    require(_pauser != address(0), "Invalid pauser address");
    require(_funder != address(0), "Invalid funder address");
    require(_token != address(0), "Invalid token address");

    __Pausable_init();
    __AccessControlEnumerable_init();

    lastSetTime = type(uint256).max;
    waitingPeriod = 6 hours;

    token = _token;

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(BOT, _bot);
    _grantRole(PAUSER, _pauser);
    _grantRole(FUNDER, _funder);
  }

  /**
   * @dev fund the distributor with interest to distribute. Only the funder (the
   *      SurfinAdapter) can call; it pulls `amount` of the interest token from itself.
   * @param amount Amount of interest to fund
   */
  function notifyReward(uint256 amount) external onlyRole(FUNDER) whenNotPaused {
    require(amount > 0, "Invalid amount");

    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

    emit RewardFunded(msg.sender, amount);
  }

  /**
   * @dev Batch claim interest. Can be called by anyone as long as the proofs are valid.
   *
   *      Claims are permissionless, so a row may already be settled by the time the batch
   *      lands; those are skipped rather than reverting everyone else. Only exact equality
   *      is tolerated — a lower total means a backwards root or a stale tree.
   * @param _accounts Addresses of claiming accounts
   * @param _totalAmounts Total amounts of interest claimable by the accounts
   * @param _proofs Merkle proofs of the claims
   */
  function batchClaim(
    address[] memory _accounts,
    uint256[] memory _totalAmounts,
    bytes32[][] memory _proofs
  ) external whenNotPaused {
    require(_accounts.length == _totalAmounts.length && _accounts.length == _proofs.length, "Invalid input lengths");

    for (uint256 i = 0; i < _accounts.length; i++) {
      if (_totalAmounts[i] == claimed[_accounts[i]]) {
        emit SkipClaim(_accounts[i], _totalAmounts[i]);
        continue;
      }
      // a lower total falls through and _claim reverts it with "Invalid total amount"
      _claim(_accounts[i], _totalAmounts[i], _proofs[i]);
    }
  }

  /**
   * @dev Claim interest. Can be called by anyone as long as proof is valid.
   * @param _account Address of the claiming account
   * @param _totalAmount total amount of interest claimable by the account
   * @param _proof Merkle proof of the claim
   */
  function claim(address _account, uint256 _totalAmount, bytes32[] memory _proof) public whenNotPaused {
    _claim(_account, _totalAmount, _proof);
  }

  /// @dev shared claim body. Both entrypoints carry `whenNotPaused`, so routing through
  ///      here does not bypass the gate.
  function _claim(address _account, uint256 _totalAmount, bytes32[] memory _proof) internal {
    require(merkleRoot != bytes32(0), "Invalid merkle root");

    uint256 claimedAmount = claimed[_account];
    require(_totalAmount > claimedAmount, "Invalid total amount");

    bytes32 leaf = keccak256(abi.encode(block.chainid, address(this), this.claim.selector, _account, _totalAmount));

    require(MerkleProof.verify(_proof, merkleRoot, leaf), "Invalid proof");

    claimed[_account] = _totalAmount;

    uint256 amount = _totalAmount - claimedAmount;
    IERC20(token).safeTransfer(_account, amount);

    emit Claimed(_account, amount, _totalAmount);
  }

  /// @dev Set pending merkle root.
  /// @param _merkleRoot New merkle root to be set as pending
  function setPendingMerkleRoot(bytes32 _merkleRoot) external onlyRole(BOT) whenNotPaused {
    require(
      _merkleRoot != bytes32(0) &&
        _merkleRoot != pendingMerkleRoot &&
        _merkleRoot != merkleRoot &&
        lastSetTime == type(uint256).max,
      "Invalid new merkle root"
    );

    pendingMerkleRoot = _merkleRoot;
    lastSetTime = block.timestamp;
    // Freeze this root's activation against the period in force right now, so a
    // later changeWaitingPeriod cannot move a deadline that is already running.
    pendingActivationTime = block.timestamp + waitingPeriod;

    emit SetPendingMerkleRoot(_merkleRoot, lastSetTime, pendingActivationTime);
  }

  /// @dev Accept the pending merkle root; only once its frozen activation time has passed
  function acceptMerkleRoot() external onlyRole(BOT) whenNotPaused {
    require(pendingMerkleRoot != bytes32(0) && pendingMerkleRoot != merkleRoot, "Invalid pending merkle root");
    require(block.timestamp >= pendingActivationTime, "Not ready to accept");

    merkleRoot = pendingMerkleRoot;
    pendingMerkleRoot = bytes32(0);
    lastSetTime = type(uint256).max;
    pendingActivationTime = 0;

    emit AcceptMerkleRoot(merkleRoot, block.timestamp);
  }

  /// @dev Revoke the pending merkle root by Manager
  function revokePendingMerkleRoot() external onlyRole(MANAGER) {
    require(pendingMerkleRoot != bytes32(0), "Pending merkle root is zero");

    pendingMerkleRoot = bytes32(0);
    lastSetTime = type(uint256).max;
    pendingActivationTime = 0;

    emit SetPendingMerkleRoot(bytes32(0), lastSetTime, 0);
  }

  /// @dev Change waiting period. Applies to roots staged AFTER this call; a root already
  ///      under review keeps the activation time frozen when it was staged.
  /// @param _waitingPeriod Waiting period to be set
  function changeWaitingPeriod(uint256 _waitingPeriod) external onlyRole(MANAGER) whenNotPaused {
    require(
      _waitingPeriod >= 6 hours && _waitingPeriod <= 7 days && _waitingPeriod != waitingPeriod,
      "Invalid waiting period"
    );
    waitingPeriod = _waitingPeriod;

    emit WaitingPeriodUpdated(_waitingPeriod);
  }

  /// @dev manager can withdraw all interest tokens from the contract in case of emergency
  /// @param _token Address of the token to withdraw
  function emergencyWithdraw(address _token) external onlyRole(MANAGER) {
    uint256 _amount = IERC20(_token).balanceOf(address(this));
    IERC20(_token).safeTransfer(msg.sender, _amount);

    emit EmergencyWithdrawal(msg.sender, _token, _amount);
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

  uint256[49] private __gap;
}
