// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

/**
 * @title Enum - Collection of enums used in Safe Smart Account contracts.
 * @author @safe-global/safe-protocol
 */
library Enum {
  enum Operation {
    Call,
    DelegateCall
  }
}
