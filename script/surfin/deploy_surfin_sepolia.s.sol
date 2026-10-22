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
 * @dev 6-decimal test USDT. MockERC20 is fixed at 18 decimals, but real USDT on ETH
 *      mainnet is 6-dec, so Sepolia deploys this override to exercise the ETH precision
 *      path (absolute-amount params like MIN_DEPOSIT are 6-dec here) before the real
 *      deploy_surfin_eth run.
 */
contract MockUSDT6 is MockERC20 {
  constructor() MockERC20("Test USDT", "USDT") {}

  function decimals() public pure override returns (uint8) {
    return 6;
  }
}

/**
 * @title DeploySurfinSepolia
 * @notice Sepolia (ETH testnet) deploy of the full Surfin Credit Fund stack. Mirrors
 *         deploy_surfin_testnet (self-contained, all roles = deployer, shortened
 *         distributor time-lock), the ONLY difference being a 6-DECIMAL mock USDT so
 *         the ETH mainnet precision path is validated before deploy_surfin_eth.
 *
 *         ALL roles (admin/manager/pauser/bot) default to the deployer; the distributor
 *         time-lock is shortened to WAITING_PERIOD for fast root-publish testing (do NOT
 *         ship that value to mainnet).
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=<key> ETHERSCAN_API_KEY=<key> \
 *     forge script script/surfin/deploy_surfin_sepolia.s.sol:DeploySurfinSepolia \
 *     --rpc-url sepolia --broadcast --verify -vvvv
 */
contract DeploySurfinSepolia is Script {
  /* ----- Test USDT: address(0) => deploy a fresh 6-dec mock; else reuse this token ----- */
  address constant TEST_USDT_OVERRIDE = address(0);

  /* ----- Launch params (6-dec, testnet-friendly) ----- */
  uint256 constant FLOOR_RATE = 3e16; // 3% hard floor (rate, precision-agnostic)
  uint256 constant PENALTY_RATE = 0.008 ether; // 0.8% early-redeem penalty (rate)
  uint256 constant MIN_DEPOSIT = 50e6; // 50 test-USDT (6-dec mock)
  uint256 constant MIN_WITHDRAW = 50e6; // 50 test-USDT (6-dec); a sub-min request must drain the balance
  uint256 constant DAILY_LIMIT = 200_000e6; // 200k per-address/day withdraw cap (6-dec)
  uint256 constant WAITING_PERIOD = 5 minutes; // shortened distributor time-lock (testnet only)

  /* ----- LP metadata ----- */
  string constant FLEX_NAME = "Surfin Flex USDT";
  string constant FLEX_SYMBOL = "sfUSDT";
  string constant LOCKED_NAME = "Surfin Locked USDT";
  string constant LOCKED_SYMBOL = "slUSDT";

  function run() public {
    require(block.chainid == 11155111, "expect Sepolia (chainId 11155111)");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPk);

    // All roles default to the deployer on testnet.
    address admin = deployer;

    console.log("Chain ID:", block.chainid);
    console.log("Deployer:", deployer);

    vm.startBroadcast(deployerPk);

    // 0. test USDT (6-dec mock unless an override is provided).
    address usdt = TEST_USDT_OVERRIDE == address(0) ? address(new MockUSDT6()) : TEST_USDT_OVERRIDE;

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

    // 6. sanity: the 6-dec asset must propagate through the 1:1 LP, so the ETH mainnet
    //    precision path is genuinely exercised on Sepolia.
    require(FlexEarnPool(flexProxy).decimals() == 6, "flex LP decimals != 6");
    require(LockedEarnPool(lockedProxy).decimals() == 6, "locked LP decimals != 6");

    console.log("==================================================");
    console.log("Surfin Credit Fund deployed on Sepolia (6-dec USDT)");
    console.log("==================================================");
    console.log("Test USDT (6-dec):        ", usdt);
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
