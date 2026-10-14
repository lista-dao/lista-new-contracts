// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LisAster } from "../../src/lisaster/LisAster.sol";
import { AsterVault } from "../../src/lisaster/AsterVault.sol";
import { LisAsterStaking } from "../../src/lisaster/LisAsterStaking.sol";
import { AsterRewards } from "../../src/lisaster/AsterRewards.sol";
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
  address operator = makeAddr("operator");
  address user = makeAddr("user");
  address other = makeAddr("other");

  uint256 internal constant DISTRIBUTOR_WAITING_PERIOD = 6 hours;

  MockERC20 internal asterToken;
  MockAstherusVault internal astherusVault;

  LisAster internal lisAster;
  AsterVault internal vault;
  LisAsterStaking internal staking;
  AsterRewards internal rewards;
  LisAsterDistributor internal distributor;

  function setUp() public virtual {
    asterToken = new MockERC20("Aster", "ASTER");
    astherusVault = new MockAstherusVault();

    // 1. Deploy all proxies first (no init) so addresses are known.
    lisAster = LisAster(address(new ERC1967Proxy(address(new LisAster()), "")));
    vault = AsterVault(address(new ERC1967Proxy(address(new AsterVault()), "")));
    staking = LisAsterStaking(address(new ERC1967Proxy(address(new LisAsterStaking()), "")));
    rewards = AsterRewards(address(new ERC1967Proxy(address(new AsterRewards()), "")));
    distributor = LisAsterDistributor(address(new ERC1967Proxy(address(new LisAsterDistributor()), "")));

    // 2. Initialize. All required roles are granted inside each initialize call.
    lisAster.initialize(admin, address(vault), "Lista Aster", "lisAster");
    vault.initialize(
      admin,
      pauser,
      manager,
      address(asterToken),
      address(astherusVault),
      address(lisAster),
      lisAsterManager,
      1, // broker (Lista default)
      0.1 ether // minDeposit
    );
    staking.initialize(admin, pauser, manager, address(lisAster));
    rewards.initialize(admin, pauser, manager, bot, address(asterToken));
    distributor.initialize(
      LisAsterDistributor.InitParams({
        admin: admin,
        manager: manager,
        bot: bot,
        pauser: pauser,
        asterToken: address(asterToken),
        lisAster: address(lisAster),
        vault: address(vault),
        staking: address(staking),
        rewards: address(rewards),
        waitingPeriod: DISTRIBUTOR_WAITING_PERIOD
      })
    );

    // 3. Rewards one-shot setDistributor (MANAGER-gated; only Rewards still wires distributor on-chain).
    vm.prank(manager);
    rewards.setDistributor(address(distributor));

    // 4. Configure the operator (ASTER reward source) so BOT can notifyRewards.
    vm.prank(manager);
    rewards.setOperator(operator);
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

  /// @dev Inject `amount` ASTER into Rewards under the bot-automated flow: operator funds and
  ///      approves, BOT calls notifyRewards. (Name kept for call-site stability.)
  function _managerNotify(uint256 amount) internal {
    asterToken.mint(operator, amount);
    vm.prank(operator);
    asterToken.approve(address(rewards), amount);
    vm.prank(bot);
    rewards.notifyRewards(amount);
  }

  /// @dev BOT pushes ASTER from Rewards to Distributor and triggers notify.
  function _botDistribute(uint256 amount) internal {
    vm.prank(bot);
    rewards.distributeRewards(amount);
  }

  /// @dev BOT stages a root, fast-forwards past `waitingPeriod`, and BOT promotes it live.
  function _setLiveMerkleRoot(bytes32 root, uint256 totalAllocated) internal {
    vm.prank(bot);
    distributor.setPendingMerkleRoot(root, totalAllocated);
    vm.warp(block.timestamp + distributor.waitingPeriod());
    vm.prank(bot);
    distributor.acceptMerkleRoot();
  }

  /* ----------------- minimal Merkle helpers (1-leaf / 2-leaf) ----------------- */

  function _leaf(address account, uint256 cumulative) internal view returns (bytes32) {
    return keccak256(abi.encode(block.chainid, account, address(asterToken), cumulative));
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
