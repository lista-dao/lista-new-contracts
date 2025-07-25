// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity 0.8.24;

import { IERC165 } from "./interfaces/IERC165.sol";
import { Enum } from "./libraries/Enum.sol";

/**
 * @title ITransactionGuard Interface
 */
interface ITransactionGuard is IERC165 {
  /**
   * @notice Checks the transaction details.
   * @dev The function needs to implement transaction validation logic.
   * @param to The address to which the transaction is intended.
   * @param value The value of the transaction in Wei.
   * @param data The transaction data.
   * @param operation The type of operation of the transaction.
   * @param safeTxGas Gas used for the transaction.
   * @param baseGas The base gas for the transaction.
   * @param gasPrice The price of gas in Wei for the transaction.
   * @param gasToken The token used to pay for gas.
   * @param refundReceiver The address which should receive the refund.
   * @param signatures The signatures of the transaction.
   * @param msgSender The address of the message sender.
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
    address payable refundReceiver,
    bytes memory signatures,
    address msgSender
  ) external;

  /**
   * @notice Checks after execution of transaction.
   * @dev The function needs to implement a check after the execution of the transaction.
   * @param hash The hash of the transaction.
   * @param success The status of the transaction execution.
   */
  function checkAfterExecution(bytes32 hash, bool success) external;
}

abstract contract BaseTransactionGuard is ITransactionGuard {
  function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
    return
      interfaceId == type(ITransactionGuard).interfaceId || // 0xe6d7a83a
      interfaceId == type(IERC165).interfaceId; // 0x01ffc9a7
  }
}
