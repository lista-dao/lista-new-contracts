// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/surfin/FlexEarnPool.sol";
import "../../src/surfin/LockedEarnPool.sol";
import "../../src/surfin/SurfinAdapter.sol";
import "../../src/surfin/InterestDistributor.sol";
import "../../src/mock/MockERC20.sol";

/**
 * @title DeploySurfinTestnet
 * @notice BSC testnet deploy of the full Surfin Credit Fund stack for iteration.
 *
 *         Differences from the mainnet scripts:
 *           - deploys a fresh MockERC20 (18-dec) as the test USDT so the stack is
 *             self-contained; swap TEST_USDT_OVERRIDE for an existing testnet token
 *             if you'd rather reuse one.
 *           - ALL roles (admin/manager/pauser/bot) default to the deployer for easy
 *             iteration; rotate later via grantRole if needed.
 *           - the InterestDistributor time-lock is shortened to WAITING_PERIOD for
 *             fast root-publish testing (do NOT ship this value to mainnet).
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=<key> BSCSCAN_API_KEY=<key> \
 *     forge script script/surfin/deploy_surfin_testnet.s.sol:DeploySurfinTestnet \
 *     --rpc-url bsc_testnet --broadcast --verify -vvvv
 */
contract DeploySurfinTestnet is Script {
  /* ----- Test USDT: address(0) => deploy a fresh MockERC20; else reuse this token ----- */
  address constant TEST_USDT_OVERRIDE = address(0);

  /* ----- Launch params (testnet-friendly) ----- */
  uint256 constant FLOOR_RATE = 3e16; // 3% hard floor
  uint256 constant PENALTY_RATE = 0.008 ether; // 0.8% early-redeem penalty
  uint256 constant MIN_DEPOSIT = 50e18; // 50 test-USDT (18-dec mock)
  uint256 constant MIN_WITHDRAW = 50e18; // 50 test-USDT (18-dec); a sub-min request must drain the balance
  uint256 constant DAILY_LIMIT = 200_000e18; // 200k per-address/day withdraw cap
  uint256 constant WAITING_PERIOD = 5 minutes; // shortened distributor time-lock (testnet only)

  /* ----- LP metadata ----- */
  string constant FLEX_NAME = "Surfin Flex USDT";
  string constant FLEX_SYMBOL = "sfUSDT";
  string constant LOCKED_NAME = "Surfin Locked USDT";
  string constant LOCKED_SYMBOL = "slUSDT";

  function run() public {
    require(block.chainid == 97, "expect BSC testnet (chainId 97)");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPk);

    // All roles default to the deployer on testnet.
    address admin = deployer;

    console.log("Chain ID:", block.chainid);
    console.log("Deployer:", deployer);

    vm.startBroadcast(deployerPk);

    // 0. test USDT (mock unless an override is provided).
    address usdt = TEST_USDT_OVERRIDE == address(0) ? address(new MockERC20("Test USDT", "USDT")) : TEST_USDT_OVERRIDE;

    // 1. FlexEarnPool + LockedEarnPool proxies (adapter placeholder = deployer).
    address flexProxy = address(
      new ERC1967Proxy(
        address(new FlexEarnPool()),
        abi.encodeCall(FlexEarnPool.initialize, (admin, admin, admin, admin, usdt, deployer, FLEX_NAME, FLEX_SYMBOL))
      )
    );
    address lockedProxy = address(
      new ERC1967Proxy(
        address(new LockedEarnPool()),
        abi.encodeCall(
          LockedEarnPool.initialize,
          (admin, admin, admin, admin, usdt, deployer, LOCKED_NAME, LOCKED_SYMBOL)
        )
      )
    );

    // 2. SurfinAdapter proxy (surfinWallet = deployer on testnet).
    address adapterProxy = address(
      new ERC1967Proxy(
        address(new SurfinAdapter(usdt)),
        abi.encodeCall(SurfinAdapter.initialize, (admin, admin, admin, admin, flexProxy, lockedProxy, deployer))
      )
    );

    // 3. InterestDistributor proxy (funder = adapter). Init order: admin, manager, bot, pauser, funder, token.
    address distributorProxy = address(
      new ERC1967Proxy(
        address(new InterestDistributor()),
        abi.encodeCall(InterestDistributor.initialize, (admin, admin, admin, admin, adapterProxy, usdt))
      )
    );

    // 4. rewire the real adapter into the pools.
    FlexEarnPool(flexProxy).setAdapter(adapterProxy);
    LockedEarnPool(lockedProxy).setAdapter(adapterProxy);

    // 5. adapter wiring + launch config + shortened distributor time-lock.
    _configure(flexProxy, lockedProxy, adapterProxy, distributorProxy, deployer);

    vm.stopBroadcast();

    console.log("==================================================");
    console.log("Surfin Credit Fund deployed on BSC testnet");
    console.log("==================================================");
    console.log("Test USDT:                ", usdt);
    console.log("FlexEarnPool proxy:       ", flexProxy);
    console.log("LockedEarnPool proxy:     ", lockedProxy);
    console.log("SurfinAdapter proxy:      ", adapterProxy);
    console.log("InterestDistributor proxy:", distributorProxy);
    console.log("all roles -> deployer:    ", deployer);
    console.log("==================================================");
  }

  /// @dev testnet wiring: interest distributor, fee sink (= deployer), rates, min deposit,
  ///      and the shortened distributor time-lock. All setters are MANAGER-gated (= deployer).
  function _configure(
    address flexProxy,
    address lockedProxy,
    address adapterProxy,
    address distributorProxy,
    address deployer
  ) internal {
    SurfinAdapter adapter = SurfinAdapter(adapterProxy);
    adapter.setInterestDistributor(distributorProxy);
    adapter.setFeeReceiver(deployer);
    adapter.setFloorRate(FLOOR_RATE);

    LockedEarnPool(lockedProxy).setPenaltyRate(PENALTY_RATE);
    FlexEarnPool(flexProxy).setMinDeposit(MIN_DEPOSIT);
    LockedEarnPool(lockedProxy).setMinDeposit(MIN_DEPOSIT);
    FlexEarnPool(flexProxy).setMinWithdraw(MIN_WITHDRAW);
    LockedEarnPool(lockedProxy).setMinWithdraw(MIN_WITHDRAW);
    FlexEarnPool(flexProxy).setDailyLimit(DAILY_LIMIT);
    LockedEarnPool(lockedProxy).setDailyLimit(DAILY_LIMIT);

    // fast root-publish iteration on testnet only.
    InterestDistributor(distributorProxy).changeWaitingPeriod(WAITING_PERIOD);
  }
}
