pragma solidity 0.8.24;
import {Enum} from "../Libraries/Enum.sol";
import {console} from "forge-std/console.sol";
import {SafeGuard} from "../SafeGuard.sol";

    /// @notice More details at https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/introspection/IERC165.sol
    interface IERC165 {
        /**
        * @dev Returns true if this contract implements the interface defined by `interfaceId`.
        * See the corresponding EIP section
        * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified
        * to learn more about how these ids are created.
        *
        * This function call must use less than 30 000 gas.
        */
        function supportsInterface(bytes4 interfaceId) external view returns (bool);
    }


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
        * @notice Checks after execution of the transaction.
        * @dev The function needs to implement a check after the execution of the transaction.
        * @param hash The hash of the transaction.
        * @param success The status of the transaction execution.
        */
        function checkAfterExecution(bytes32 hash, bool success) external;
    } 

contract GnosisSafeMock{
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH = 0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
    bytes32 internal constant GUARD_STORAGE_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 private constant SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;
    uint256 public nonce;
    
    function setGuard(address guard) external  {
        if (guard != address(0) && !ITransactionGuard(guard).supportsInterface(type(ITransactionGuard).interfaceId))
            revert("GS300");
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            sstore(GUARD_STORAGE_SLOT, guard)
        }
    }

    function getGuard() public view returns (address guard) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            guard := sload(GUARD_STORAGE_SLOT)
        }
        /* solhint-enable no-inline-assembly */
    }


    function domainSeparator() public view returns (bytes32) {
        uint256 chainId;
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            chainId := chainid()
        }
        /* solhint-enable no-inline-assembly */

        return keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, chainId, this));
    }


    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) public view returns (bytes32 txHash) {
        bytes32 domainHash = domainSeparator();

        // We opted for using assembly code here, because the way Solidity compiler we use (0.7.6) allocates memory is
        // inefficient. We do not need to allocate memory for temporary variables to be used in the keccak256 call.
        //
        // WARNING: We do not clean potential dirty bits in types that are less than 256 bits (addresses and Enum.Enum.Operation)
        // The solidity assembly types that are smaller than 256 bit can have dirty high bits according to the spec (see the Warning in https://docs.soliditylang.org/en/latest/assembly.html#access-to-external-variables-functions-and-libraries).
        // However, we read most of the data from calldata, where the variables are not packed, and the only variable we read from storage is uint256 nonce.
        // This is not a problem, however, we must consider this for potential future changes.
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            // Get the free memory pointer
            let ptr := mload(0x40)

            // Step 1: Hash the transaction data
            // Copy transaction data to memory and hash it
            calldatacopy(ptr, data.offset, data.length)
            let calldataHash := keccak256(ptr, data.length)

            // Step 2: Prepare the SafeTX struct for hashing
            // Layout in memory:
            // ptr +   0: SAFE_TX_TYPEHASH (constant defining the struct hash)
            // ptr +  32: to address
            // ptr +  64: value
            // ptr +  96: calldataHash
            // ptr + 128: operation
            // ptr + 160: safeTxGas
            // ptr + 192: baseGas
            // ptr + 224: gasPrice
            // ptr + 256: gasToken
            // ptr + 288: refundReceiver
            // ptr + 320: nonce
            mstore(ptr, SAFE_TX_TYPEHASH)
            mstore(add(ptr, 32), to)
            mstore(add(ptr, 64), value)
            mstore(add(ptr, 96), calldataHash)
            mstore(add(ptr, 128), operation)
            mstore(add(ptr, 160), safeTxGas)
            mstore(add(ptr, 192), baseGas)
            mstore(add(ptr, 224), gasPrice)
            mstore(add(ptr, 256), gasToken)
            mstore(add(ptr, 288), refundReceiver)
            mstore(add(ptr, 320), _nonce)

            // Step 3: Calculate the final EIP-712 hash
            // First, hash the SafeTX struct (352 bytes total length)
            mstore(add(ptr, 64), keccak256(ptr, 352))
            // Store the EIP-712 prefix (0x1901), note that integers are left-padded
            // so the EIP-712 encoded data starts at add(ptr, 30)
            mstore(ptr, 0x1901)
            // Store the domain separator
            mstore(add(ptr, 32), domainHash)
            // Calculate the hash
            txHash := keccak256(add(ptr, 30), 66)
        }
        /* solhint-enable no-inline-assembly */
    }

    function addAuditor(address auditor) public{
        SafeGuard(getGuard()).addAuditor(auditor);
    }

     function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success) {
        bytes32 txHash;
        {
            txHash = getTransactionHash( // Transaction info
                to,
                value,
                data,
                operation,
                safeTxGas,
                // Payment info
                baseGas,
                gasPrice,
                gasToken,
                refundReceiver,
                // Signature info
                // We use the post-increment here, so the current nonce value is used and incremented afterwards.
                nonce++
            );
        }
        address guard = getGuard();
        {
            if (guard != address(0)) {
                ITransactionGuard(guard).checkTransaction(
                    // Transaction info
                    to,
                    value,
                    data,
                    operation,
                    safeTxGas,
                    // Payment info
                    baseGas,
                    gasPrice,
                    gasToken,
                    payable(refundReceiver),
                    // Signature info
                    signatures,
                    msg.sender
                );
            }
        }
        success = true;
    }
}