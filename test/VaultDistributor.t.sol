// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Hashes } from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

import { MockERC20 } from "../src/mock/MockERC20.sol";
import { VaultDistributor } from "../src/VaultDistributor.sol";

contract VaultDistributorTest is Test {
  MockERC20 lpToken;
  MockERC20 USD1;
  VaultDistributor distributor;

  address admin = makeAddr("admin");
  address bot = makeAddr("bot");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address user1 = makeAddr("user1");
  address user2 = makeAddr("user2");
  address user3 = makeAddr("user3");
  address user4 = makeAddr("user4");

  bytes32 public root;
  bytes32[] public leafs;
  bytes32[] public l2;

  function setUp() public {
    lpToken = new MockERC20("lpToken", "lpToken");
    USD1 = new MockERC20("USD1", "USD1");

    VaultDistributor distributorImpl = new VaultDistributor();

    address[] memory tokens = new address[](1);
    tokens[0] = address(USD1);

    ERC1967Proxy proxy_ = new ERC1967Proxy(
      address(distributorImpl),
      abi.encodeWithSelector(distributorImpl.initialize.selector, admin, manager, bot, pauser, address(lpToken), tokens)
    );

    distributor = VaultDistributor(address(proxy_));

    assertTrue(distributor.tokens(address(USD1)));
    assertEq(distributor.lpToken(), address(lpToken));

    assertEq(type(uint256).max, distributor.lastSetTime());
    assertEq(1 days, distributor.waitingPeriod());

    assertEq(bytes32(0), distributor.merkleRoot());
    assertEq(bytes32(0), distributor.pendingMerkleRoot());

    // calc hash of leaf
    leafs.push(
      keccak256(
        abi.encode(
          block.chainid,
          address(distributor),
          distributor.claim.selector,
          user1,
          address(USD1),
          123e18,
          123e18
        )
      )
    );
    leafs.push(
      keccak256(
        abi.encode(
          block.chainid,
          address(distributor),
          distributor.claim.selector,
          user2,
          address(USD1),
          456e18,
          456e18
        )
      )
    );
    leafs.push(
      keccak256(
        abi.encode(
          block.chainid,
          address(distributor),
          distributor.claim.selector,
          user3,
          address(USD1),
          789e18,
          789e18
        )
      )
    );
    leafs.push(
      keccak256(
        abi.encode(
          block.chainid,
          address(distributor),
          distributor.claim.selector,
          user4,
          address(USD1),
          369e18,
          369e18
        )
      )
    );

    // calc hash of layer 2
    l2.push(Hashes.commutativeKeccak256(leafs[0], leafs[1]));
    l2.push(Hashes.commutativeKeccak256(leafs[2], leafs[3]));

    // calc root
    root = Hashes.commutativeKeccak256(l2[0], l2[1]);
  }

  function test_pendingMerkleRoot() public {
    bytes32 _merkleRoot = bytes32(0x0000000000000000000000000000000000000000000000000000000000000001);

    vm.startPrank(bot);
    vm.expectRevert("Invalid pending merkle root");
    distributor.acceptMerkleRoot();

    distributor.setPendingMerkleRoot(_merkleRoot); // success

    vm.expectRevert("Invalid new merkle root");
    distributor.setPendingMerkleRoot(_merkleRoot); // revert on duplicate

    assertEq(_merkleRoot, distributor.pendingMerkleRoot());
    assertEq(block.timestamp, distributor.lastSetTime());
    assertEq(bytes32(0), distributor.merkleRoot());

    vm.expectRevert("Not ready to accept");
    distributor.acceptMerkleRoot();

    skip(1 days);
    distributor.acceptMerkleRoot(); // success

    assertEq(bytes32(0), distributor.pendingMerkleRoot());
    assertEq(type(uint).max, distributor.lastSetTime());
    assertEq(_merkleRoot, distributor.merkleRoot());

    vm.expectRevert("Invalid pending merkle root");
    distributor.acceptMerkleRoot();
  }

  function test_pendingMerkleRoot_wrong() public {
    bytes32 _merkleRoot1 = bytes32(0x0000000000000000000000000000000000000000000000000000000000000001);
    bytes32 _merkleRoot2 = bytes32(0x0000000000000000000000000000000000000000000000000000000000000002);

    vm.startPrank(bot);
    vm.expectRevert("Invalid pending merkle root");
    distributor.acceptMerkleRoot();

    distributor.setPendingMerkleRoot(_merkleRoot1); // success

    skip(1 hours);

    vm.expectRevert("Invalid new merkle root");
    distributor.setPendingMerkleRoot(_merkleRoot2); // revert on repeat
    vm.stopPrank();

    assertEq(_merkleRoot1, distributor.pendingMerkleRoot());

    vm.prank(manager);
    distributor.revokePendingMerkleRoot();
    assertEq(bytes32(0), distributor.pendingMerkleRoot());
    assertEq(type(uint).max, distributor.lastSetTime());

    vm.startPrank(bot);
    distributor.setPendingMerkleRoot(_merkleRoot2); // success
    assertEq(_merkleRoot2, distributor.pendingMerkleRoot());
    assertEq(block.timestamp, distributor.lastSetTime());

    skip(1 days);
    distributor.acceptMerkleRoot(); // success
    assertEq(bytes32(0), distributor.pendingMerkleRoot());
    assertEq(type(uint).max, distributor.lastSetTime());
    assertEq(_merkleRoot2, distributor.merkleRoot());

    vm.expectRevert("Invalid new merkle root");
    distributor.setPendingMerkleRoot(_merkleRoot2); // revert on existing merkle root
  }

  function test_emergencyWithdraw() public {
    deal(address(lpToken), address(distributor), 99 ether);

    vm.expectRevert();
    distributor.emergencyWithdraw(address(lpToken));

    vm.prank(manager);
    distributor.emergencyWithdraw(address(lpToken)); // success

    assertEq(99 ether, lpToken.balanceOf(address(manager)));
    assertEq(0, lpToken.balanceOf(address(distributor)));
  }

  function test_revokePendingMerkleRoot() public {
    bytes32 _merkleRoot = bytes32(0x0000000000000000000000000000000000000000000000000000000000000002);

    vm.expectRevert("Pending merkle root is zero");
    vm.prank(manager);
    distributor.revokePendingMerkleRoot();

    vm.prank(bot);
    distributor.setPendingMerkleRoot(_merkleRoot);
    assertEq(_merkleRoot, distributor.pendingMerkleRoot());
    assertEq(block.timestamp, distributor.lastSetTime());

    vm.prank(manager);
    distributor.revokePendingMerkleRoot();
    assertEq(bytes32(0), distributor.pendingMerkleRoot());
    assertEq(type(uint).max, distributor.lastSetTime());

    vm.prank(bot);
    distributor.setPendingMerkleRoot(_merkleRoot);
    assertEq(_merkleRoot, distributor.pendingMerkleRoot());
    assertEq(block.timestamp, distributor.lastSetTime());

    vm.prank(pauser);
    distributor.pause();
    assertTrue(distributor.paused());

    vm.prank(manager);
    distributor.revokePendingMerkleRoot();
    assertEq(bytes32(0), distributor.pendingMerkleRoot());
    assertEq(type(uint).max, distributor.lastSetTime());
  }

  function test_changeWaitingPeriod() public {
    vm.expectRevert("Invalid waiting period");
    vm.startPrank(manager);
    distributor.changeWaitingPeriod(5 hours);

    distributor.changeWaitingPeriod(7 hours); // success
    assertEq(7 hours, distributor.waitingPeriod());

    vm.expectRevert("Invalid waiting period");
    distributor.changeWaitingPeriod(7 hours);
  }

  function test_claim_ok() public {
    test_setMerkleRoot_ok();

    deal(address(lpToken), user1, 123e18);
    deal(address(USD1), address(distributor), 123e18);

    bytes32[] memory proof = new bytes32[](2);
    proof[0] = leafs[1];
    proof[1] = l2[1];

    vm.startPrank(user1);
    lpToken.approve(address(distributor), 123e18);
    distributor.claim(user1, address(USD1), 123e18, 123e18, proof);
    vm.stopPrank();
  }

  function test_setMerkleRoot_ok() public {
    vm.startPrank(bot);
    distributor.setPendingMerkleRoot(root);
    skip(distributor.waitingPeriod());
    distributor.acceptMerkleRoot();
    vm.stopPrank();
  }
}
