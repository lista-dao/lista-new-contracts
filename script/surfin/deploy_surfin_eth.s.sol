// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/surfin/FlexEarnPool.sol";
import "../../src/surfin/LockedEarnPool.sol";
import "../../src/surfin/SurfinAdapter.sol";
import "../../src/surfin/InterestDistributor.sol";

/**
 * @title DeploySurfinEth
 * @notice Ethereum mainnet deploy of the Surfin Credit Fund stack: FlexEarnPool +
 *         LockedEarnPool sharing one SurfinAdapter, plus the cumulative Merkle
 *         InterestDistributor.
 *
 *         Identical wiring to deploy_surfin_bsc; the ONLY differences are the ETH
 *         externals and USDT's 6-decimal precision (BSC USDT is 18-dec). The 1:1 LP
 *         auto-follows asset.decimals(), and floor/penalty/fee are 1e18 rates, so
 *         only absolute-amount params (MIN_DEPOSIT / daily limits) are scaled to 6-dec.
 *
 *         Role convention: DEFAULT_ADMIN / MANAGER stay on the deployer for post-deploy
 *         verification, then rotate via transfer_surfin_roles.s.sol; PAUSER / BOT are
 *         pre-wired to their lista production holders here.
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=<key> ETHERSCAN_API_KEY=<key> \
 *     forge script script/surfin/deploy_surfin_eth.s.sol:DeploySurfinEth \
 *     --rpc-url eth --broadcast --verify -vvvv
 */
contract DeploySurfinEth is Script {
  /* ----- Ethereum mainnet externals ----- */
  address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6 decimals

  /* ----- Surfin receiving wallet (off-chain custody/multisig) ----- */
  // TODO: replace with the real Surfin receiving multisig before mainnet deploy.
  address constant SURFIN_WALLET = 0x000000000000000000000000000000000000dEaD;

  /* ----- Final role holders pre-wired at deploy (lista production) ----- */
  address constant PAUSER_ADDR = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
  address constant BOT_ADDR = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  address constant FEE_RECEIVER = 0x09702Ea135d9D707DD51f530864f2B9220aAD87B;

  /* ----- Launch params (tune before mainnet; all MANAGER-adjustable later) ----- */
  uint256 constant FLOOR_RATE = 3e16; // 3% hard floor (= contract default; rate, precision-agnostic)
  uint256 constant PENALTY_RATE = 0.008 ether; // 0.8% early-redeem penalty (= contract default; rate)
  uint256 constant MIN_DEPOSIT = 50e6; // 50 USDT (6-dec on ETH)
  uint256 constant MIN_WITHDRAW = 50e6; // 50 USDT (6-dec); a sub-min request must drain the balance
  uint256 constant FLEX_DAILY_LIMIT = 200_000e6; // 200k per-address/day flex withdraw cap (6-dec)
  uint256 constant LOCKED_DAILY_LIMIT = 200_000e6; // 200k per-address/day locked early-redeem cap (6-dec)

  /* ----- LP metadata ----- */
  string constant FLEX_NAME = "Surfin Flex USDT";
  string constant FLEX_SYMBOL = "sfUSDT";
  string constant LOCKED_NAME = "Surfin Locked USDT";
  string constant LOCKED_SYMBOL = "slUSDT";

  function run() public {
    require(block.chainid == 1, "expect ETH mainnet (chainId 1)");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPk);

    // admin / manager: deployer holds both TEMPORARILY, handed over in transfer_surfin_roles.
    address admin = deployer;
    address manager = deployer;

    console.log("Chain ID:  ", block.chainid);
    console.log("Deployer:  ", deployer);
    console.log("USDT:      ", USDT);

    vm.startBroadcast(deployerPk);

    // 1. FlexEarnPool + LockedEarnPool proxies (adapter placeholder = deployer).
    //    Impl is inlined into the proxy constructor to keep run()'s stack shallow.
    address flexProxy = address(
      new ERC1967Proxy(
        address(new FlexEarnPool()),
        abi.encodeCall(
          FlexEarnPool.initialize,
          (admin, manager, PAUSER_ADDR, BOT_ADDR, USDT, deployer, FLEX_NAME, FLEX_SYMBOL)
        )
      )
    );
    address lockedProxy = address(
      new ERC1967Proxy(
        address(new LockedEarnPool()),
        abi.encodeCall(
          LockedEarnPool.initialize,
          (admin, manager, PAUSER_ADDR, BOT_ADDR, USDT, deployer, LOCKED_NAME, LOCKED_SYMBOL)
        )
      )
    );

    // 2. SurfinAdapter proxy (real pool addresses + Surfin receiving wallet).
    address adapterProxy = address(
      new ERC1967Proxy(
        address(new SurfinAdapter(USDT)),
        abi.encodeCall(
          SurfinAdapter.initialize,
          (admin, manager, PAUSER_ADDR, BOT_ADDR, flexProxy, lockedProxy, SURFIN_WALLET)
        )
      )
    );

    // 3. InterestDistributor proxy (funder = adapter, the only caller of notifyReward).
    //    NB init order: admin, manager, bot, pauser, funder, token.
    address distributorProxy = address(
      new ERC1967Proxy(
        address(new InterestDistributor()),
        abi.encodeCall(InterestDistributor.initialize, (admin, manager, BOT_ADDR, PAUSER_ADDR, adapterProxy, USDT))
      )
    );

    // 4. rewire the real adapter into the pools (DEFAULT_ADMIN-gated, deployer holds it).
    FlexEarnPool(flexProxy).setAdapter(adapterProxy);
    LockedEarnPool(lockedProxy).setAdapter(adapterProxy);

    // 5. adapter wiring + launch config (all MANAGER-gated, deployer holds MANAGER).
    _configure(flexProxy, lockedProxy, adapterProxy, distributorProxy);

    vm.stopBroadcast();

    _verify(flexProxy, lockedProxy, adapterProxy, distributorProxy);
    _log(flexProxy, lockedProxy, adapterProxy, distributorProxy, deployer);
  }

  /// @dev adapter interest wiring + fee/floor/penalty/limit config. Split out of run()
  ///      to keep the stack shallow. Every setter is MANAGER-gated.
  function _configure(address flexProxy, address lockedProxy, address adapterProxy, address distributorProxy) internal {
    SurfinAdapter adapter = SurfinAdapter(adapterProxy);
    adapter.setInterestDistributor(distributorProxy);
    adapter.setFeeReceiver(FEE_RECEIVER);
    adapter.setFloorRate(FLOOR_RATE);

    LockedEarnPool(lockedProxy).setPenaltyRate(PENALTY_RATE);

    if (MIN_DEPOSIT > 0) {
      FlexEarnPool(flexProxy).setMinDeposit(MIN_DEPOSIT);
      LockedEarnPool(lockedProxy).setMinDeposit(MIN_DEPOSIT);
    }
    if (MIN_WITHDRAW > 0) {
      FlexEarnPool(flexProxy).setMinWithdraw(MIN_WITHDRAW);
      LockedEarnPool(lockedProxy).setMinWithdraw(MIN_WITHDRAW);
    }
    if (FLEX_DAILY_LIMIT > 0) FlexEarnPool(flexProxy).setDailyLimit(FLEX_DAILY_LIMIT);
    if (LOCKED_DAILY_LIMIT > 0) LockedEarnPool(lockedProxy).setDailyLimit(LOCKED_DAILY_LIMIT);
  }

  /// @dev post-deploy sanity assertions on critical wiring.
  function _verify(
    address flexProxy,
    address lockedProxy,
    address adapterProxy,
    address distributorProxy
  ) internal view {
    SurfinAdapter adapter = SurfinAdapter(adapterProxy);
    require(adapter.flexPool() == flexProxy, "adapter.flexPool mismatch");
    require(adapter.lockedPool() == lockedProxy, "adapter.lockedPool mismatch");
    require(adapter.interestDistributor() == distributorProxy, "adapter.interestDistributor mismatch");
    require(adapter.surfinWallet() == SURFIN_WALLET, "adapter.surfinWallet mismatch");
    require(FlexEarnPool(flexProxy).adapter() == adapterProxy, "flex.adapter mismatch");
    require(LockedEarnPool(lockedProxy).adapter() == adapterProxy, "locked.adapter mismatch");
    require(InterestDistributor(distributorProxy).token() == USDT, "distributor.token mismatch");
  }

  function _log(
    address flexProxy,
    address lockedProxy,
    address adapterProxy,
    address distributorProxy,
    address deployer
  ) internal pure {
    console.log("==================================================");
    console.log("Surfin Credit Fund deployed on Ethereum mainnet");
    console.log("==================================================");
    console.log("FlexEarnPool proxy:       ", flexProxy);
    console.log("LockedEarnPool proxy:     ", lockedProxy);
    console.log("SurfinAdapter proxy:      ", adapterProxy);
    console.log("InterestDistributor proxy:", distributorProxy);
    console.log("--------------------------------------------------");
    console.log("admin/manager (deployer, rotate via transfer script):", deployer);
    console.log("pauser:", PAUSER_ADDR);
    console.log("bot:   ", BOT_ADDR);
    console.log("--------------------------------------------------");
    console.log("Next (runbook): 1) replace SURFIN_WALLET / FEE_RECEIVER placeholders;");
    console.log("                2) fund/enable first locked cohort via setCohort (BOT);");
    console.log("                3) transfer_surfin_roles.s.sol (admin->TimeLock, manager->multisig).");
    console.log("==================================================");
  }
}
