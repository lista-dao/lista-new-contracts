// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test, console } from "forge-std/Test.sol";

import { Enum } from "../../src/safe/libraries/Enum.sol";
import { ISafe } from "./interfaces/ISafe.sol";
import { SafeGuard } from "../../src/safe/SafeGuard.sol";

contract SafeGuardTest is Test {
  SafeGuard public safeGuard;
  ISafe public safe = ISafe(0x5C0F11c927216E4D780E2a219b06632Fb027274E); // multi-sig
  address public manager = address(0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253); // TimeLock
  address public executor = address(0x38A750E77038f35578e19c680c67A694241633E2); // multi-sig owner
  address public executor2 = makeAddr("executor2"); // not multi-sig owner

  function setUp() public {
    // fork mainnet
    vm.createSelectFork("https://rpc.ankr.com/bsc", 43797673);

    safeGuard = new SafeGuard(manager, new address[](0));
    assertEq(safeGuard.manager(), manager);

    vm.startPrank(address(safe));
    safe.setGuard(address(safeGuard));
    vm.stopPrank();
  }

  /**
   * @notice Test the executor who is the owner of the multi-sig can execute the transaction.
   */
  function testExecutorOfOwner() public {
    bytes
      memory data = hex"2f2ff15d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007d274a68393e8b8a2ccf19a2ce4ba3518735253";

    // call execTransaction with non-executor
    vm.startPrank(executor);
    vm.expectRevert(bytes("SafeGuard: NotExecutor"));
    bool success = safe.execTransaction(
      address(0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B),
      0,
      data,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      payable(address(0)),
      hex"490a313238449c120c00a0eedb8437bf5b15154ad5cb8edcd794651d5f5c115877d666faab8d33929ed2fb49f2396dce5118f7090b6c445527186c62af106abf20449c90ce141e833617b953e6d8137bbfbf328e23bb55129c4b6968a90452a0703773b56c0241e226a57acd524ce3162aad5e5a42379179cac5147e9287e85ddb1f700ef45c1522a855c079248f7db4b8fea4f80e1fc3b0b15d3bf3ed25e314d4733132831740d284942125cd2328d39478a7fdb7d683d96b2fa04f7ba908de6fbe1c"
    );
    require(!success, "Safe transaction with owner should be failed");
    vm.stopPrank();

    // add executor
    vm.startPrank(manager);
    safeGuard.addExecutor(executor);
    vm.stopPrank();

    // call execTransaction with executor
    vm.startPrank(executor);
    success = safe.execTransaction(
      address(0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B),
      0,
      data,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      payable(address(0)),
      hex"490a313238449c120c00a0eedb8437bf5b15154ad5cb8edcd794651d5f5c115877d666faab8d33929ed2fb49f2396dce5118f7090b6c445527186c62af106abf20449c90ce141e833617b953e6d8137bbfbf328e23bb55129c4b6968a90452a0703773b56c0241e226a57acd524ce3162aad5e5a42379179cac5147e9287e85ddb1f700ef45c1522a855c079248f7db4b8fea4f80e1fc3b0b15d3bf3ed25e314d4733132831740d284942125cd2328d39478a7fdb7d683d96b2fa04f7ba908de6fbe1c"
    );
    require(success, "Safe transaction with owner failed");
    vm.stopPrank();
  }

  /**
   * @notice Test the executor who is not the owner of the multi-sig cannot execute the transaction.
   */
  function testExecutorOfNoneOwner() public {
    bytes
      memory data = hex"2f2ff15d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007d274a68393e8b8a2ccf19a2ce4ba3518735253";

    // call execTransaction with non-executor
    vm.startPrank(executor2);
    vm.expectRevert(bytes("SafeGuard: NotExecutor"));
    bool success = safe.execTransaction(
      address(0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B),
      0,
      data,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      payable(address(0)),
      hex"490a313238449c120c00a0eedb8437bf5b15154ad5cb8edcd794651d5f5c115877d666faab8d33929ed2fb49f2396dce5118f7090b6c445527186c62af106abf20449c90ce141e833617b953e6d8137bbfbf328e23bb55129c4b6968a90452a0703773b56c0241e226a57acd524ce3162aad5e5a42379179cac5147e9287e85ddb1f700ef45c1522a855c079248f7db4b8fea4f80e1fc3b0b15d3bf3ed25e314d4733132831740d284942125cd2328d39478a7fdb7d683d96b2fa04f7ba908de6fbe1c"
    );
    require(!success, "Safe transaction with non-owner should be failed");
    vm.stopPrank();

    // add executor
    vm.startPrank(manager);
    safeGuard.addExecutor(executor2);
    vm.stopPrank();

    // call execTransaction with executor
    vm.startPrank(executor2);
    success = safe.execTransaction(
      address(0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B),
      0,
      data,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      payable(address(0)),
      hex"490a313238449c120c00a0eedb8437bf5b15154ad5cb8edcd794651d5f5c115877d666faab8d33929ed2fb49f2396dce5118f7090b6c445527186c62af106abf20449c90ce141e833617b953e6d8137bbfbf328e23bb55129c4b6968a90452a0703773b56c0241e226a57acd524ce3162aad5e5a42379179cac5147e9287e85ddb1f700ef45c1522a855c079248f7db4b8fea4f80e1fc3b0b15d3bf3ed25e314d4733132831740d284942125cd2328d39478a7fdb7d683d96b2fa04f7ba908de6fbe1c"
    );
    require(success, "Safe transaction with non-owner failed");
    vm.stopPrank();
  }

  /**
   * @notice Test manager executor
   */
  function testMangerExecutor() public {
    // only manager can add executor
    vm.expectRevert(bytes("SafeGuard: Not Authorized"));
    safeGuard.addExecutor(executor);

    // manager can add executor
    vm.startPrank(manager);
    safeGuard.addExecutor(executor);
    vm.stopPrank();
    // check executor
    assertEq(safeGuard.executors()[0], executor);

    // only manager can remove executor
    vm.expectRevert(bytes("SafeGuard: Not Authorized"));
    safeGuard.removeExecutor(executor);

    // manager can remove executor
    vm.startPrank(manager);
    safeGuard.removeExecutor(executor);
    vm.stopPrank();
    // check executor
    assertEq(safeGuard.executors().length, 0);

    // manager batch add executors
    address[] memory executors = new address[](2);
    executors[0] = executor;
    executors[1] = executor2;

    // only manager can add executor
    vm.expectRevert(bytes("SafeGuard: Not Authorized"));
    safeGuard.addExecutors(executors);

    // only manager can add executor
    vm.startPrank(manager);
    safeGuard.addExecutors(executors);
    vm.stopPrank();
    // check executor
    assertEq(safeGuard.executors().length, 2);
    assertEq(safeGuard.executors()[0], executors[0]);
    assertEq(safeGuard.executors()[1], executors[1]);
  }

  /**
   * @notice Test change manager
   */
  function testChangeManager() public {
    // only manager can set pending manager
    vm.expectRevert(bytes("SafeGuard: Not Authorized"));
    safeGuard.setPendingManager(executor);

    // manager can set pending manager
    vm.startPrank(manager);
    safeGuard.setPendingManager(executor);
    vm.stopPrank();
    // check pending manager
    assertEq(safeGuard.pendingManager(), executor);

    // only pending manager can accept manager
    vm.expectRevert(bytes("SafeGuard: Not Authorized"));
    safeGuard.acceptManager();

    // pending manager only can accept manager after delay time
    vm.startPrank(executor);
    vm.expectRevert(bytes("SafeGuard: No Delay End"));
    safeGuard.acceptManager();
    vm.stopPrank();

    // pending manager can accept manager after delay time
    skip(safeGuard.DELAY() + 1);
    vm.startPrank(executor);
    safeGuard.acceptManager();
    vm.stopPrank();

    // check manager
    assertEq(safeGuard.manager(), executor);
    // check pending manager
    assertEq(safeGuard.pendingManager(), address(0));
  }
}
