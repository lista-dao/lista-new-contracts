// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { GnosisSafeMock } from "./GnosisSafeMock.sol";
import { SafeGuard } from "../../src/safe/SafeGuard.sol";
import { Enum } from "../../src/safe/libraries/Enum.sol";
import { console } from "forge-std/console.sol";

contract SGTest is Test {
  GnosisSafeMock mockWallet;
  SafeGuard guard;
  uint8[] public fixtureOperationuint = [0, 1];
  function setUp() public {
    console.log("Setup loading");
    address deployer = vm.addr(199);
    vm.startPrank(deployer);
    mockWallet = new GnosisSafeMock();
    guard = new SafeGuard();
    mockWallet.setGuard(address(guard));
    vm.stopPrank();
    address auditor = vm.addr(200);
    mockWallet.addAuditor(auditor);
    console.log("Setup completed");
  }

  function testFuzz_executeApproved(
    address to,
    uint256 value,
    bytes memory data,
    uint8 operationuint,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    address refundReceiver
  ) public {
    Enum.Operation operation = operationuint == 1 ? Enum.Operation.DelegateCall : Enum.Operation.Call;
    vm.startPrank(vm.addr(200));
    uint256[] memory currentNonce = new uint256[](1);
    currentNonce[0] = mockWallet.nonce();
    bytes32 txhash = guard.encodeTransactionData(
      to,
      value,
      data,
      operation,
      safeTxGas,
      baseGas,
      gasPrice,
      gasToken,
      refundReceiver,
      currentNonce[0]
    );
    bytes32[] memory txhashes = new bytes32[](1);
    txhashes[0] = txhash;
    guard.addMessageHash(address(mockWallet), currentNonce, txhashes);
    console.log("added message hash: ");

    console.logBytes32(txhash);
    assert(
      mockWallet.execTransaction(to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, "")
    );
  }
}
