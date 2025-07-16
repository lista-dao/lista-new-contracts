// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MockERC20 } from "../src/mock/MockERC20.sol";
import { LendingRewardsDistributorV2 } from "../src/LendingRewardsDistributorV2.sol";

contract LendingRewardsDistributorV2Test is Test {
  MockERC20 lista;
  MockERC20 lisUSD;
  LendingRewardsDistributorV2 distributor;

  address admin = makeAddr("admin");
  address bot = makeAddr("bot");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");

  function setUp() public {
    lista = new MockERC20("lista", "lista");
    lisUSD = new MockERC20("lisUSD", "lisUSD");

    LendingRewardsDistributorV2 distributorImpl = new LendingRewardsDistributorV2();

    address[] memory tokens = new address[](2);
    tokens[0] = address(lista);
    tokens[1] = address(lisUSD);

    ERC1967Proxy proxy_ = new ERC1967Proxy(
      address(distributorImpl),
      abi.encodeWithSelector(LendingRewardsDistributorV2.initialize.selector, admin, manager, bot, pauser, tokens)
    );

    distributor = LendingRewardsDistributorV2(address(proxy_));

    assertTrue(distributor.tokens(address(lista)));
    assertTrue(distributor.tokens(address(lisUSD)));

    assertEq(type(uint256).max, distributor.lastSetTime());
    assertEq(1 days, distributor.waitingPeriod());

    assertEq(bytes32(0), distributor.merkleRoot());
    assertEq(bytes32(0), distributor.pendingMerkleRoot());
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
    deal(address(lista), address(distributor), 99 ether);

    vm.expectRevert();
    distributor.emergencyWithdraw(address(lista));

    vm.prank(manager);
    distributor.emergencyWithdraw(address(lista)); // success

    assertEq(99 ether, lista.balanceOf(address(manager)));
    assertEq(0, lista.balanceOf(address(distributor)));
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
}
