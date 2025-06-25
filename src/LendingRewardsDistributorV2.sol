// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { ILendingRewardsDistributorV2 } from "./interface/ILendingRewardsDistributorV2.sol";

/**
 * @title Emission Rewards Distributor for Lista Lending
 * @author Lista DAO
 * @dev Distribute rebate rewards to Lista Lending users
 */
contract LendingRewardsDistributorV2 is
  ILendingRewardsDistributorV2,
  AccessControlEnumerableUpgradeable,
  PausableUpgradeable,
  UUPSUpgradeable
{
  using SafeERC20 for IERC20;

  /// @dev current merkle root
  bytes32 public merkleRoot;

  /// @dev Token whitelist
  mapping(address => bool) public tokens;

  /// @dev userAddress => token => total claimed amount
  mapping(address => mapping(address => uint256)) public claimed;

  /// @dev the next merkle root to be set
  bytes32 public pendingMerkleRoot;

  /// @dev last time pending merkle root was set
  uint256 public lastSetTime;

  /// @dev the waiting period before accepting the pending merkle root; 1 day by default
  uint256 public waitingPeriod;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant BOT = keccak256("BOT");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  event Claimed(address indexed account, address indexed token, uint256 amount, uint256 totalAmount);
  event SetPendingMerkleRoot(bytes32 merkleRoot, uint256 lastSetTime);
  event AcceptMerkleRoot(bytes32 merkleRoot, uint256 acceptedTime);
  event WaitingPeriodUpdated(uint256 waitingPeriod);
  event SetTokenWhitelist(address indexed token, bool whitelisted);
  event EmergencyWithdrawal(address to, address token, uint256 amount);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @param _admin Address of the admin
   * @param _manager Address of the manager
   * @param _bot Address of the bot
   * @param _pauser Address of the pauser
   * @param _tokens Address of tokens to be supported
   */
  function initialize(
    address _admin,
    address _manager,
    address _bot,
    address _pauser,
    address[] memory _tokens
  ) external initializer {
    require(_admin != address(0), "Invalid admin address");
    require(_manager != address(0), "Invalid manager address");
    require(_bot != address(0), "Invalid bot address");
    require(_pauser != address(0), "Invalid pauser address");
    require(_tokens.length > 0, "Empty tokens array");

    __Pausable_init();
    __AccessControl_init();
    __UUPSUpgradeable_init();

    lastSetTime = type(uint256).max;
    waitingPeriod = 1 days;

    for (uint256 i = 0; i < _tokens.length; i++) {
      require(_tokens[i] != address(0), "Invalid token address");
      tokens[_tokens[i]] = true; // initializing supported tokens

      emit SetTokenWhitelist(_tokens[i], true);
    }

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(BOT, _bot);
    _grantRole(PAUSER, _pauser);
  }

  /**
   * @dev Batch claim rebates. Can be called by anyone as long as proof is valid.
   * @param _accounts Addresses of rebating accounts
   * @param _tokens Addresses of the tokens to claim
   * @param _totalAmounts Total amounts of tokens rebatable to the accounts
   * @param _proofs Merkle proofs of the claims
   */
  function batchClaim(
    address[] memory _accounts,
    address[] memory _tokens,
    uint256[] memory _totalAmounts,
    bytes32[][] memory _proofs
  ) external {
    require(
      _accounts.length == _tokens.length &&
        _accounts.length == _totalAmounts.length &&
        _accounts.length == _proofs.length,
      "Invalid input lengths"
    );

    for (uint256 i = 0; i < _tokens.length; i++) {
      claim(_accounts[i], _tokens[i], _totalAmounts[i], _proofs[i]);
    }
  }

  /**
   * @dev Claim a rebate. Can be called by anyone as long as proof is valid.
   * @param _account Address of rebating account
   * @param _token Address of the token to claim
   * @param _totalAmount total amount of token rebatable to the account
   * @param _proof Merkle proof of the claim
   */
  function claim(address _account, address _token, uint256 _totalAmount, bytes32[] memory _proof) public whenNotPaused {
    require(merkleRoot != bytes32(0), "Invalid merkle root");
    require(tokens[_token], "Token not supported");

    uint256 claimedAmount = claimed[_account][_token];
    require(_totalAmount > claimedAmount, "Invalid total amount");

    bytes32 leaf = keccak256(
      abi.encode(block.chainid, address(this), this.claim.selector, _account, _token, _totalAmount)
    );

    require(MerkleProof.verify(_proof, merkleRoot, leaf), "Invalid proof");

    claimed[_account][_token] = _totalAmount;

    uint256 amount = _totalAmount - claimedAmount;
    if (amount > 0) IERC20(_token).safeTransfer(_account, amount);

    emit Claimed(_account, _token, amount, _totalAmount);
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

    emit SetPendingMerkleRoot(_merkleRoot, lastSetTime);
  }

  /// @dev Accept the pending merkle root; pending merkle root can only be accepted after 1 day of setting
  function acceptMerkleRoot() external onlyRole(BOT) whenNotPaused {
    require(pendingMerkleRoot != bytes32(0) && pendingMerkleRoot != merkleRoot, "Invalid pending merkle root");
    require(block.timestamp >= lastSetTime + waitingPeriod, "Not ready to accept");

    merkleRoot = pendingMerkleRoot;
    pendingMerkleRoot = bytes32(0);
    lastSetTime = type(uint256).max;

    emit AcceptMerkleRoot(merkleRoot, block.timestamp);
  }

  /// @dev Revoke the pending merkle root by Manager
  function revokePendingMerkleRoot() external onlyRole(MANAGER) {
    require(pendingMerkleRoot != bytes32(0), "Pending merkle root is zero");

    pendingMerkleRoot = bytes32(0);
    lastSetTime = type(uint256).max;

    emit SetPendingMerkleRoot(bytes32(0), lastSetTime);
  }

  /// @dev Change waiting period.
  /// @param _waitingPeriod Waiting period to be set
  function changeWaitingPeriod(uint256 _waitingPeriod) external onlyRole(MANAGER) whenNotPaused {
    require(_waitingPeriod >= 6 hours && _waitingPeriod != waitingPeriod, "Invalid waiting period");
    waitingPeriod = _waitingPeriod;

    emit WaitingPeriodUpdated(_waitingPeriod);
  }

  /// @dev Set token whitelist
  /// @param _tokens Addresses of the tokens to be whitelisted
  /// @param _whitelist Boolean array indicating whether the token is whitelisted
  function setTokenWhitelist(address[] memory _tokens, bool[] memory _whitelist) external onlyRole(MANAGER) {
    require(_tokens.length == _whitelist.length, "Invalid input lengths");

    for (uint256 i = 0; i < _tokens.length; i++) {
      require(_tokens[i] != address(0), "Invalid token address");
      tokens[_tokens[i]] = _whitelist[i];

      emit SetTokenWhitelist(_tokens[i], _whitelist[i]);
    }
  }

  /// @dev manager can withdraw all reward tokens from the contract in case of emergency
  /// @param token Address of the token to withdraw
  function emergencyWithdraw(address token) external onlyRole(MANAGER) {
    uint256 _amount = IERC20(token).balanceOf(address(this));
    IERC20(token).safeTransfer(msg.sender, _amount);

    emit EmergencyWithdrawal(msg.sender, token, _amount);
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
}
