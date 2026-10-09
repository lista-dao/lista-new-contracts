// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev Minimal contract signer: valid when the ECDSA signature recovers to `owner`.
contract ERC1271Signer is IERC1271 {
  address public immutable owner;

  constructor(address _owner) {
    owner = _owner;
  }

  function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
    (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(hash, signature);
    if (err == ECDSA.RecoverError.NoError && recovered == owner) {
      return IERC1271.isValidSignature.selector;
    }
    return bytes4(0);
  }
}
