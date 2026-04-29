// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LisAster } from "../../src/lisaster/LisAster.sol";
import { AsterVault } from "../../src/lisaster/AsterVault.sol";
import { LisAsterStaking } from "../../src/lisaster/LisAsterStaking.sol";
import { LisAsterRewards } from "../../src/lisaster/LisAsterRewards.sol";
import { LisAsterDistributor } from "../../src/lisaster/LisAsterDistributor.sol";

import { MockERC20 } from "../../src/mock/MockERC20.sol";
import { MockAstherusVault } from "./mocks/MockAstherusVault.sol";

/// @dev Common setUp that deploys the full lisAster system with mocks. Subclasses just inherit.
abstract contract LisAsterBase is Test {
  address admin = makeAddr("admin");
  address pauser = makeAddr("pauser");
  address bot = makeAddr("bot");
  address manager = makeAddr("manager");
  address lisAsterManager = makeAddr("lisAsterManager");
  address user = makeAddr("user");
  address other = makeAddr("other");

  MockERC20 internal asterToken;
  MockAstherusVault internal astherusVault;

  LisAster internal lisAster;
  AsterVault internal vault;
  LisAsterStaking internal staking;
  LisAsterRewards internal rewards;
  LisAsterDistributor internal distributor;

  function setUp() public virtual {
    asterToken = new MockERC20("Aster", "ASTER");
    astherusVault = new MockAstherusVault();

    // 1. Deploy all proxies first (no init) so addresses are known.
    lisAster = LisAster(address(new ERC1967Proxy(address(new LisAster()), "")));
    vault = AsterVault(address(new ERC1967Proxy(address(new AsterVault()), "")));
    staking = LisAsterStaking(address(new ERC1967Proxy(address(new LisAsterStaking()), "")));
    rewards = LisAsterRewards(address(new ERC1967Proxy(address(new LisAsterRewards()), "")));
    distributor = LisAsterDistributor(address(new ERC1967Proxy(address(new LisAsterDistributor()), "")));

    // 2. Initialize. All required roles are granted inside each initialize call.
    lisAster.initialize(admin, address(vault), "Lista Aster", "lisAster");
    vault.initialize(
      admin,
      pauser,
      address(asterToken),
      address(astherusVault),
      address(lisAster),
      lisAsterManager,
      1, // broker (Lista default)
      0.1 ether // minDeposit
    );
    staking.initialize(admin, pauser, address(lisAster));
    rewards.initialize(admin, pauser, manager, bot, address(asterToken), address(lisAster), address(vault));
    distributor.initialize(admin, manager, pauser, address(lisAster), address(staking), address(rewards));

    // 3. Rewards one-shot setDistributor (MANAGER-gated; only Rewards still wires distributor on-chain).
    vm.prank(manager);
    rewards.setDistributor(address(distributor));
  }

  /* ----------------- helpers ----------------- */

  function _giveAster(address to, uint256 amount) internal {
    asterToken.mint(to, amount);
  }

  /// @dev User path: approve ASTER + vault.deposit.
  function _userDeposit(address from, uint256 amount, address receiver) internal {
    vm.startPrank(from);
    asterToken.approve(address(vault), amount);
    vault.deposit(amount, receiver);
    vm.stopPrank();
  }

  /// @dev Rewards.MANAGER receives ASTER returned via Astherus and re-deposits via Vault,
  ///      minting lisAster to Rewards.
  function _managerNotify(uint256 amount) internal {
    asterToken.mint(manager, amount);
    vm.startPrank(manager);
    asterToken.approve(address(rewards), amount);
    rewards.notifyRewards(amount);
    vm.stopPrank();
  }

  /// @dev BOT pushes lisAster to Distributor and triggers notify.
  function _botDistribute(uint256 amount) internal {
    vm.prank(bot);
    rewards.distributeRewards(amount);
  }

  /* ----------------- minimal Merkle helpers (1-leaf / 2-leaf) ----------------- */

  function _leaf(address account, uint256 cumulative) internal view returns (bytes32) {
    return keccak256(abi.encode(block.chainid, account, address(lisAster), cumulative));
  }

  function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
    return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
  }

  /// @dev Single-leaf Merkle: root == leaf, proof == [].
  function _singleLeafRoot(address account, uint256 cumulative) internal view returns (bytes32) {
    return _leaf(account, cumulative);
  }

  /// @dev Builds a 2-leaf Merkle tree and returns (root, proofForLeaf0, proofForLeaf1).
  function _twoLeafTree(
    address acc0,
    uint256 cum0,
    address acc1,
    uint256 cum1
  ) internal view returns (bytes32 root, bytes32[] memory proof0, bytes32[] memory proof1) {
    bytes32 l0 = _leaf(acc0, cum0);
    bytes32 l1 = _leaf(acc1, cum1);
    root = _hashPair(l0, l1);
    proof0 = new bytes32[](1);
    proof0[0] = l1;
    proof1 = new bytes32[](1);
    proof1[0] = l0;
  }
}
