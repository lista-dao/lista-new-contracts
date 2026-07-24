// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/surfin/SurfinAdapter.sol";
import "../../src/surfin/FlexEarnPool.sol";
import "../../src/surfin/LockedEarnPool.sol";
import "../../src/surfin/InterestDistributor.sol";
import "../../src/mock/MockERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * Shared fixture for the Surfin Credit Fund test suite. Wires the full system the
 * way the deploy script does — flex pool, locked pool, adapter, and the cumulative
 * Merkle interest distributor — so every suite (invariants, conflicts, module unit
 * tests, and end-to-end journeys) inherits one consistent setup.
 *
 * Deployment mirrors the existing surfin regression suites
 * (SurfinAdapterGuard / SurfinAdapterSettleRecall): ERC1967 proxies, the same
 * admin/manager/pauser/bot roles, and 18-decimal USDT.
 */
abstract contract SurfinTestBase is Test {
  MockERC20 usdt;
  SurfinAdapter adapter;
  FlexEarnPool flex;
  LockedEarnPool locked;
  InterestDistributor distributor;

  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address bot = makeAddr("bot");
  address surfinWallet = makeAddr("surfinWallet");
  address feeReceiver = makeAddr("feeReceiver");

  address alice = makeAddr("alice");
  address bob = makeAddr("bob");
  address charlie = makeAddr("charlie");

  uint256 constant FLOOR_RATE = 3e16; // 3% hard floor

  function setUp() public virtual {
    usdt = new MockERC20("USDT", "USDT");

    FlexEarnPool flexImpl = new FlexEarnPool();
    LockedEarnPool lockedImpl = new LockedEarnPool();
    SurfinAdapter adapterImpl = new SurfinAdapter(address(usdt));
    InterestDistributor distImpl = new InterestDistributor();

    flex = FlexEarnPool(
      address(
        new ERC1967Proxy(
          address(flexImpl),
          abi.encodeWithSelector(
            flexImpl.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(usdt),
            address(this),
            "Flex",
            "FLEX"
          )
        )
      )
    );
    locked = LockedEarnPool(
      address(
        new ERC1967Proxy(
          address(lockedImpl),
          abi.encodeWithSelector(
            lockedImpl.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(usdt),
            address(this),
            "Locked",
            "LOCK"
          )
        )
      )
    );
    adapter = SurfinAdapter(
      address(
        new ERC1967Proxy(
          address(adapterImpl),
          abi.encodeWithSelector(
            adapterImpl.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(flex),
            address(locked),
            surfinWallet
          )
        )
      )
    );
    // interest distributor: note the initialize order (admin, manager, bot, pauser,
    // funder, token); the funder must be the adapter, which is the only caller of
    // notifyReward.
    distributor = InterestDistributor(
      address(
        new ERC1967Proxy(
          address(distImpl),
          abi.encodeWithSelector(
            distImpl.initialize.selector,
            admin,
            manager,
            bot,
            pauser,
            address(adapter),
            address(usdt)
          )
        )
      )
    );

    vm.startPrank(admin);
    flex.setAdapter(address(adapter));
    locked.setAdapter(address(adapter));
    vm.stopPrank();

    vm.startPrank(manager);
    adapter.setInterestDistributor(address(distributor));
    adapter.setFeeReceiver(feeReceiver);
    vm.stopPrank();
  }

  /* ---- helpers ---- */

  /// @dev flex deposit: mint, approve, deposit; funds land in the adapter.
  function _depositFlex(address who, uint256 amount) internal {
    usdt.mint(who, amount);
    vm.startPrank(who);
    usdt.approve(address(flex), amount);
    flex.deposit(amount, who);
    vm.stopPrank();
  }

  /// @dev create/enable a cohort (BOT-gated).
  function _setCohort(
    uint256 cohortId,
    uint256 termDays,
    uint256 depositDeadline,
    uint256 maturityTime,
    bool enabled
  ) internal {
    vm.prank(bot);
    locked.setCohort(cohortId, termDays, depositDeadline, maturityTime, enabled);
  }

  /// @dev locked deposit into an existing cohort; funds land in the adapter.
  function _depositLocked(address who, uint256 cohortId, uint256 amount, bool autoRenew) internal {
    usdt.mint(who, amount);
    vm.startPrank(who);
    usdt.approve(address(locked), amount);
    locked.deposit(cohortId, amount, who, autoRenew);
    vm.stopPrank();
  }

  /// @dev drop raw USDT onto the adapter to emulate recalled/idle cash without
  ///      touching the deployed book value (settleRecall path is tested separately).
  function _fundAdapter(uint256 amount) internal {
    usdt.mint(address(adapter), amount);
  }

  /// @dev manager settleRecall wrapper (mint + approve + call).
  function _settleRecall(
    uint256 recalledAmount,
    uint256 lockedCoverAmount,
    uint256 feeAmount,
    uint256 bookValue
  ) internal {
    usdt.mint(manager, recalledAmount);
    vm.startPrank(manager);
    usdt.approve(address(adapter), recalledAmount);
    adapter.settleRecall(recalledAmount, lockedCoverAmount, feeAmount, bookValue);
    vm.stopPrank();
  }

  /// @dev single-leaf cumulative Merkle root for the distributor (root == leaf, empty proof).
  function _leaf(address account, uint256 totalAmount) internal view returns (bytes32) {
    return keccak256(abi.encode(block.chainid, address(distributor), distributor.claim.selector, account, totalAmount));
  }

  /// @dev publish a single-leaf root through the two-step timelocked flow.
  function _publishRoot(bytes32 root) internal {
    vm.prank(bot);
    distributor.setPendingMerkleRoot(root);
    vm.warp(block.timestamp + distributor.waitingPeriod());
    vm.prank(bot);
    distributor.acceptMerkleRoot();
  }
}
