// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity 0.8.24;

import { BaseTransactionGuard } from "./BaseTransactionGuard.sol";
import { ISafe } from "./interfaces/ISafe.sol";
import { Enum } from "./libraries/Enum.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title SafeGuard - Allow message hash submission and executor whitelist.
 * @author Lista
 */
contract SafeGuard is BaseTransactionGuard {
  error InvalidMessagehash(bytes32 message);

  using EnumerableSet for EnumerableSet.AddressSet;
  bytes32 private constant SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;

  /* ============ Global States ============ */
  // account => executors
  mapping(address => EnumerableSet.AddressSet) private _executors;

  // account => bot
  mapping(address => EnumerableSet.AddressSet) private _auditors;
  // account => nonce => hash
  mapping(address => mapping(uint256 => bytes32)) public messagehash;

  /* ============ Events ============ */
  event ExecutorAdded(address indexed account, address indexed executor);
  event ExecutorRemoved(address indexed account, address indexed executor);
  event AuditorAdded(address indexed account, address indexed auditor);
  event AuditorRemoved(address indexed account, address indexed auditor);
  //logging event in case of auditors
  event SafeTxData(
    address to,
    uint256 value,
    bytes data,
    uint8 operation,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    address refundReceiver,
    uint256 nonce,
    bytes32 messagehash
  );

  constructor() {}

  // solhint-disable-next-line payable-fallback
  fallback() external {
    // We don't revert on fallback to avoid issues in case of a Safe upgrade
    // E.g. The expected check method might change and then the Safe would be locked.
  }

  modifier onlyContract() {
    require(isContract(msg.sender), "SafeGuard: Contract is not allowed");
    _;
  }

  modifier onlyAuditor(address _vault) {
    require(_auditors[_vault].contains(msg.sender), "SafeGuard: NotAuditor");
    _;
  }

  function addMessageHash(address _vault, uint256 _nonce, bytes32 _hash) external onlyAuditor(_vault) {}

  function addMessageHash(
    address _vault,
    uint256[] memory _nonce_list,
    bytes32[] memory _hash_list
  ) external onlyAuditor(_vault) {
    require(_nonce_list.length == _hash_list.length, "SafeGuard: ZeroHash");
    for (uint256 i = 0; i < _nonce_list.length; ++i) {
      _addMessageHash(_vault, _nonce_list[i], _hash_list[i]);
    }
  }

  function _addMessageHash(address _vault, uint256 _nonce, bytes32 _hash) internal {
    require(_hash != bytes32(0), "SafeGuard: ZeroHash");
    require(_nonce >= ISafe(_vault).nonce(), "SafeGuard: Nonce not valid");
    messagehash[_vault][_nonce] = _hash;
  }

  function getVaultNonce(address _vault) external view returns (uint256) {
    return ISafe(_vault).nonce();
  }

  function executors(address _vault) external view returns (address[] memory _executorsArray) {
    return _executors[_vault].values();
  }

  function auditors(address _vault) external view returns (address[] memory _auditorsArray) {
    return _auditors[_vault].values();
  }

  function addExecutors(address[] calldata _executorsList) external onlyContract {
    require(_executorsList.length > 0, "SafeGuard: InvalidExecutors");
    address _account = msg.sender;
    EnumerableSet.AddressSet storage exe = _executors[_account];
    for (uint256 i; i < _executorsList.length; i++) {
      require(_executorsList[i] != address(0), "SafeGuard: ZeroAddress");
      require(exe.add(_executorsList[i]), "SafeGuard: ExecutorExists");
      emit ExecutorAdded(_account, _executorsList[i]);
    }
  }

  function addAuditors(address[] calldata _auditorsList) external onlyContract {
    require(_auditorsList.length > 0, "SafeGuard: InvalidAuditors");
    address _account = msg.sender;
    EnumerableSet.AddressSet storage axe = _auditors[_account];
    for (uint256 i; i < _auditorsList.length; i++) {
      require(_auditorsList[i] != address(0), "SafeGuard: ZeroAddress");
      require(axe.add(_auditorsList[i]), "SafeGuard: AuditorExists");
      emit AuditorAdded(_account, _auditorsList[i]);
    }
  }

  function addExecutor(address _executor) external onlyContract {
    require(_executor != address(0), "SafeGuard: InvalidExecutor");
    address _account = msg.sender;
    EnumerableSet.AddressSet storage exe = _executors[_account];
    require(exe.add(_executor), "SafeGuard: ExecutorExists");
    emit ExecutorAdded(_account, _executor);
  }

  function addAuditor(address _auditor) external onlyContract {
    require(_auditor != address(0), "SafeGuard: InvalidAuditor");
    address _account = msg.sender;
    EnumerableSet.AddressSet storage axe = _auditors[_account];
    require(axe.add(_auditor), "SafeGuard: AuditorExists");
    emit AuditorAdded(_account, _auditor);
  }

  function removeExecutor(address _executor) external onlyContract {
    require(_executor != address(0), "SafeGuard: InvalidExecutor");
    address _account = msg.sender;
    EnumerableSet.AddressSet storage exe = _executors[_account];
    require(exe.remove(_executor), "SafeGuard: InvalidExecutor");
    emit ExecutorRemoved(_account, _executor);
  }

  function removeAuditor(address _auditor) external onlyContract {
    require(_auditor != address(0), "SafeGuard: InvalidAuditor");
    address _account = msg.sender;
    EnumerableSet.AddressSet storage axe = _auditors[_account];
    require(axe.remove(_auditor), "SafeGuard: InvalidAuditor");
    emit AuditorRemoved(_account, _auditor);
  }

  function isContract(address addr) internal view returns (bool) {
    uint size;
    assembly {
      size := extcodesize(addr)
    }
    return size > 0;
  }

  /**
   * @notice Called by the Safe contract before a transaction is executed.
   * @dev Reverts if the transaction is not executed by an owner.
   * @param msgSender Executor of the transaction.
   */
  function checkTransaction(
    address to,
    uint256 value,
    bytes memory data,
    Enum.Operation operation,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    // solhint-disable-next-line no-unused-vars
    address payable refundReceiver,
    bytes memory,
    address msgSender
  ) external override {
    uint256 executerLength = _executors[msg.sender].length();
    uint256 auditorLength = _auditors[msg.sender].length();
    if (executerLength != 0) {
      require(_executors[msg.sender].contains(msgSender), "SafeGuard: NotExecutor");
    }

    if (auditorLength != 0) {
      if (to != address(msg.sender) || data.length != 0) {
        //Check hash
        bytes32 hash = encodeTransactionData(
          to,
          value,
          data,
          operation,
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          (ISafe(msg.sender).nonce()) - 1
        );
        require(messagehash[msg.sender][ISafe(msg.sender).nonce() - 1] == hash, "SafeGuard: InvalidHash");
        emit SafeTxData(
          to,
          value,
          data,
          uint8(operation),
          safeTxGas,
          baseGas,
          gasPrice,
          gasToken,
          refundReceiver,
          (ISafe(msg.sender).nonce() - 1),
          hash
        );
      }
    }
  }

  /// @dev Returns the bytes that are hashed to be signed by owners.
  /// @param to Destination address.
  /// @param value Ether value.
  /// @param data Data payload.
  /// @param operation Operation type.
  /// @param safeTxGas Gas that should be used for the safe transaction.
  /// @param baseGas Gas costs for that are independent of the transaction execution(e.g. base transaction fee, signature check, payment of the refund)
  /// @param gasPrice Maximum gas price that should be used for this transaction.
  /// @param gasToken Token address (or 0 if ETH) that is used for the payment.
  /// @param refundReceiver Address of receiver of gas payment (or 0 if tx.origin).
  /// @param _nonce Transaction nonce.
  /// @return Message hash bytes.
  function encodeTransactionData(
    address to,
    uint256 value,
    bytes memory data,
    Enum.Operation operation,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    address refundReceiver,
    uint256 _nonce
  ) public pure returns (bytes32) {
    bytes32 safeTxHash = keccak256(
      abi.encode(
        SAFE_TX_TYPEHASH,
        to,
        value,
        keccak256(data),
        operation,
        safeTxGas,
        baseGas,
        gasPrice,
        gasToken,
        refundReceiver,
        _nonce
      )
    );
    return safeTxHash;
  }

  /**
   * @notice Called by the Safe contract after a transaction is executed.
   * @dev No-op.
   */
  function checkAfterExecution(bytes32, bool) external view override {}
}
