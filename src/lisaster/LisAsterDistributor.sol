// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { ILisAsterDistributor } from "./interface/ILisAsterDistributor.sol";
import { ILisAsterStaking } from "./interface/ILisAsterStaking.sol";

/// @title LisAsterDistributor
/// @notice Cumulative-style Merkle distributor. Single overwrite-on-update root; leaves carry
///         each account's lifetime cumulative entitlement, and users claim
///         `cumulative - claimed` deltas with the latest proof in one call.
contract LisAsterDistributor is
  ILisAsterDistributor,
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
  address public staking;
  address public rewards;

  /* MERKLE STATE */
  bytes32 public merkleRoot;
  uint256 public merkleRootUpdatedAt;
  uint256 public totalAllocated; // Sum of cumulativeAmount across leaves of the current root

  /* ACCOUNTING */
  uint256 public totalNotified; // Lifetime inflow (incremented by Rewards.distributeRewards)
  uint256 public totalClaimed; // Lifetime amount already claimed
  mapping(address => uint256) public claimed; // Per-account lifetime claimed amount

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  function initialize(
    address admin,
    address manager,
    address pauser,
    address lisAster_,
    address staking_,
    address rewards_
  ) external initializer {
    require(admin != address(0), "admin is zero");
    require(manager != address(0), "manager is zero");
    require(pauser != address(0), "pauser is zero");
    require(lisAster_ != address(0), "lisAster is zero");
    require(staking_ != address(0), "staking is zero");
    require(rewards_ != address(0), "rewards is zero");

    __AccessControlEnumerable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(PAUSER, pauser);

    lisAster = lisAster_;
    staking = staking_;
    rewards = rewards_;
  }

  /* RECORD INFLOW */
  /// @notice Pulls `amount` lisAster from Rewards via transferFrom and bumps `totalNotified`.
  /// @dev Rewards must `forceApprove(distributor, amount)` before this call.
  function notifyRewards(uint256 amount) external override whenNotPaused {
    require(msg.sender == rewards, "not rewards");
    require(amount > 0, "zero amount");
    IERC20(lisAster).safeTransferFrom(msg.sender, address(this), amount);
    totalNotified += amount;
    emit Notified(amount);
  }

  /* MERKLE ROOT */
  function setMerkleRoot(bytes32 root, uint256 newTotalAllocated) external override onlyRole(MANAGER) {
    require(root != bytes32(0), "zero root");
    require(newTotalAllocated >= totalAllocated, "allocated decrease");
    require(newTotalAllocated <= totalNotified, "exceeds notified");
    merkleRoot = root;
    merkleRootUpdatedAt = block.timestamp;
    totalAllocated = newTotalAllocated;
    emit MerkleRootSet(root, newTotalAllocated);
  }

  /* USER CLAIM */
  function claim(
    address account,
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) external override whenNotPaused nonReentrant {
    uint256 payable_ = _consume(account, cumulativeAmount, proof);
    IERC20(lisAster).safeTransfer(account, payable_);
    emit Claimed(account, payable_, cumulativeAmount);
  }

  function claimAndStake(
    address account,
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) external override whenNotPaused nonReentrant {
    uint256 payable_ = _consume(account, cumulativeAmount, proof);
    IERC20(lisAster).forceApprove(staking, payable_);
    ILisAsterStaking(staking).stakeFor(account, payable_);
    IERC20(lisAster).forceApprove(staking, 0);
    emit ClaimedAndStaked(account, payable_, cumulativeAmount);
  }

  /* VIEW */
  function claimable(
    address account,
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) external view override returns (uint256) {
    if (merkleRoot == bytes32(0)) return 0;
    bytes32 leaf = keccak256(abi.encode(block.chainid, account, lisAster, cumulativeAmount));
    if (MerkleProof.processProofCalldata(proof, leaf) != merkleRoot) return 0;
    if (cumulativeAmount <= claimed[account]) return 0;
    return cumulativeAmount - claimed[account];
  }

  /* INTERNAL */
  function _consume(
    address account,
    uint256 cumulativeAmount,
    bytes32[] calldata proof
  ) internal returns (uint256 payable_) {
    require(merkleRoot != bytes32(0), "no root");
    bytes32 leaf = keccak256(abi.encode(block.chainid, account, lisAster, cumulativeAmount));
    require(MerkleProof.verifyCalldata(proof, merkleRoot, leaf), "invalid proof");

    uint256 already = claimed[account];
    require(cumulativeAmount > already, "nothing to claim");
    payable_ = cumulativeAmount - already;
    claimed[account] = cumulativeAmount;
    totalClaimed += payable_;
  }

  /* ADMIN */
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(PAUSER) {
    _unpause();
  }

  /// @notice Escape hatch for stuck or mis-routed tokens (e.g. tokens accidentally sent to this
  ///         contract, or lisAster that needs to be evacuated). Funds are sent to the MANAGER
  ///         caller. Does not adjust accounting, so if lisAster is withdrawn the team must
  ///         restage `totalNotified`/`totalAllocated` (or upgrade) before normal claims resume.
  function emergencyWithdraw(address token, uint256 amount) external onlyRole(MANAGER) {
    require(token != address(0), "zero token");
    require(amount > 0, "zero amount");
    IERC20(token).safeTransfer(msg.sender, amount);
    emit EmergencyWithdrawn(token, msg.sender, amount);
  }

  /* UUPS */
  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
