// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { BaseTransactionGuard } from "./BaseTransactionGuard.sol";
import { Enum } from "./libraries/Enum.sol";

/**
 * @title SafeGuard - Only allows owners to execute transactions that meet expectations.
 * @author Lista
 */
contract SafeGuard is BaseTransactionGuard {
  using EnumerableSet for EnumerableSet.AddressSet;

  // account => executors
  mapping(address => EnumerableSet.AddressSet) private _executors;

  address public manager;
  address public pendingManager;
  uint256 public pendingDelayEnd;
  uint256 public constant DELAY = 7200;

  /* ============ Events ============ */
  event ExecutorAdded(address indexed account, address indexed executor);
  event ExecutorRemoved(address indexed account, address indexed executor);
  event PendingManagerChanged(address indexed pendingManager);
  event ManagerChanged(address indexed previousManager, address indexed newManager);

  constructor(address _manager) {
    require(_manager != address(0), "SafeGuard: ZeroAddress");
    manager = _manager;
    emit ManagerChanged(address(0), manager);
  }

  // solhint-disable-next-line payable-fallback
  fallback() external {
    // We don't revert on fallback to avoid issues in case of a Safe upgrade
    // E.g. The expected check method might change and then the Safe would be locked.
  }

  function executors(address _account) external view returns (address[] memory _executorsArray) {
    return _executors[_account].values();
  }

  function addExecutors(address _account, address[] calldata _executorsList) external onlyManager {
    require(_account != address(0), "SafeGuard: InvalidAccount");
    require(_executorsList.length > 0, "SafeGuard: InvalidExecutors");
    EnumerableSet.AddressSet storage executors = _executors[_account];
    for (uint256 i; i < _executorsList.length; i++) {
      require(_executorsList[i] != address(0), "SafeGuard: ZeroAddress");
      require(executors.add(_executorsList[i]), "SafeGuard: ExecutorExists");
      emit ExecutorAdded(_account, _executorsList[i]);
    }
  }

  function addExecutor(address _account, address _executor) external onlyManager {
    require(_account != address(0), "SafeGuard: InvalidAccount");
    require(_executor != address(0), "SafeGuard: InvalidExecutor");
    EnumerableSet.AddressSet storage executors = _executors[_account];
    require(executors.add(_executor), "SafeGuard: ExecutorExists");
    emit ExecutorAdded(_account, _executor);
  }

  function removeExecutor(address _account, address _executor) external onlyManager {
    require(_account != address(0), "SafeGuard: InvalidAccount");
    require(_executor != address(0), "SafeGuard: InvalidExecutor");
    EnumerableSet.AddressSet storage executors = _executors[_account];
    require(executors.remove(_executor), "SafeGuard: InvalidExecutor");
    emit ExecutorRemoved(_account, _executor);
  }

  /**
   * @notice Called by the Safe contract before a transaction is executed.
   * @dev Reverts if the transaction is not executed by an owner.
   * @param msgSender Executor of the transaction.
   */
  function checkTransaction(
    address,
    uint256,
    bytes memory,
    Enum.Operation,
    uint256,
    uint256,
    uint256,
    address,
    // solhint-disable-next-line no-unused-vars
    address payable,
    bytes memory,
    address msgSender
  ) external view override {
    require(_executors[msg.sender].contains(msgSender), "SafeGuard: NotExecutor");
  }

  /**
   * @notice Called by the Safe contract after a transaction is executed.
   * @dev No-op.
   */
  function checkAfterExecution(bytes32, bool) external view override {}

  function setPendingManager(address _pendingManager) external onlyManager {
    require(_pendingManager != address(0), "SafeGuard: ZeroAddress");
    pendingDelayEnd = block.timestamp + DELAY;
    pendingManager = _pendingManager;
    emit PendingManagerChanged(pendingManager);
  }

  function acceptManager() external onlyPendingManager {
    require(pendingDelayEnd <= block.timestamp, "SafeGuard: DelayNotEnd");
    address previousManager = manager;
    manager = pendingManager;
    delete pendingManager;
    emit ManagerChanged(previousManager, manager);
  }

  modifier onlyManager() {
    require(msg.sender == manager, "SafeGuard: NotAuthorized");
    _;
  }

  modifier onlyPendingManager() {
    require(msg.sender == pendingManager, "SafeGuard: NotAuthorized");
    _;
  }
}
