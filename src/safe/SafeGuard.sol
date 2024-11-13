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

  EnumerableSet.AddressSet internal _executors;

  address public manager;
  address public pendingManager;
  uint256 public pendingDelayEnd;
  uint256 public constant DELAY = 7200;

  /* ============ Events ============ */
  event ExecutorAdded(address indexed executor);
  event ExecutorRemoved(address indexed executor);
  event PendingManagerChanged(address indexed pendingManager);
  event ManagerChanged(address indexed previousManager, address indexed newManager);

  constructor(address _manager, address[] memory _executorList) {
    if (_manager == address(0)) revert("SafeGuard: ZeroAddress");
    manager = _manager;
    emit ManagerChanged(address(0), manager);

    for (uint256 i; i < _executorList.length; i++) {
      if (_executorList[i] == address(0)) revert("SafeGuard: ZeroAddress");
      if (!_executors.add(_executorList[i])) revert("SafeGuard: InvalidExecutor");
      emit ExecutorAdded(_executorList[i]);
    }
  }

  // solhint-disable-next-line payable-fallback
  fallback() external {
    // We don't revert on fallback to avoid issues in case of a Safe upgrade
    // E.g. The expected check method might change and then the Safe would be locked.
  }

  function executors() external view returns (address[] memory _executorsArray) {
    return _executors.values();
  }

  function addExecutors(address[] calldata _executorsList) external onlyManager {
    for (uint256 i; i < _executorsList.length; i++) {
      if (_executorsList[i] == address(0)) revert("SafeGuard: ZeroAddress");
      if (!_executors.add(_executorsList[i])) revert("SafeGuard: InvalidExecutor");
      emit ExecutorAdded(_executorsList[i]);
    }
  }

  function addExecutor(address _executor) external onlyManager {
    if (_executor == address(0)) revert("SafeGuard: ZeroAddress");
    if (!_executors.add(_executor)) revert("SafeGuard: InvalidExecutor");
    emit ExecutorAdded(_executor);
  }

  function removeExecutor(address _executor) external onlyManager {
    if (_executor == address(0)) revert("SafeGuard: ZeroAddress");
    if (!_executors.remove(_executor)) revert("SafeGuard: InvalidExecutor");
    emit ExecutorRemoved(_executor);
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
    if (!_executors.contains(msgSender)) {
      revert("SafeGuard: NotExecutor");
    }
  }

  /**
   * @notice Called by the Safe contract after a transaction is executed.
   * @dev No-op.
   */
  function checkAfterExecution(bytes32, bool) external view override {}

  function setPendingManager(address _pendingManager) external onlyManager {
    if (_pendingManager == address(0)) revert("SafeGuard: ZeroAddress");
    pendingDelayEnd = block.timestamp + DELAY;
    pendingManager = _pendingManager;
    emit PendingManagerChanged(pendingManager);
  }

  function acceptManager() external onlyPendingManager {
    if (pendingDelayEnd >= block.timestamp) {
      revert("SafeGuard: No Delay End");
    }
    address previousManager = manager;
    manager = pendingManager;
    delete pendingManager;
    emit ManagerChanged(previousManager, manager);
  }

  modifier onlyManager() {
    if (address(msg.sender) != address(manager)) revert("SafeGuard: Not Authorized");
    _;
  }

  modifier onlyPendingManager() {
    if (address(msg.sender) != address(pendingManager)) revert("SafeGuard: Not Authorized");
    _;
  }
}
