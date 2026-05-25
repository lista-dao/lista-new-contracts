// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { AsterRewards } from "../../src/lisaster/AsterRewards.sol";
import { LisAsterDistributor } from "../../src/lisaster/LisAsterDistributor.sol";

/// @title DeployAsterRewardsV2Bsc
/// @notice BSC mainnet migration deploy: replaces the deprecated lisAster-denominated
///         Rewards + Distributor with ASTER-denominated v2 contracts. The retained
///         LisAster / AsterVault / LisAsterStaking proxies are reused as-is.
///
///         Roles follow the same convention as `deploy_lisaster_bsc.s.sol`:
///           - DEFAULT_ADMIN / MANAGER stay on the deployer for post-deploy verification.
///           - PAUSER / BOT are pre-wired to their production holders here.
///
///         Run AFTER the deprecated proxies have been paused (see runbook).
///
///         Run: forge script script/lisaster/deploy_lisaster_rewards_v2_bsc.s.sol:DeployAsterRewardsV2Bsc \
///                 --rpc-url bsc --broadcast --verify -vvvv
contract DeployAsterRewardsV2Bsc is Script {
  /* ----- BSC mainnet externals ----- */
  address constant ASTER_TOKEN = 0x000Ae314E2A2172a039B26378814C252734f556A;

  /* ----- Retained lisAster proxies (already on BSC mainnet) ----- */
  address constant LIS_ASTER_PROXY = 0xa17A497D20cC143508FE3b63578b13ba6b9c9f06;
  address constant ASTER_VAULT_PROXY = 0xb3Df1b695D720dDc5906005DD5448DB160687C42;
  address constant LIS_ASTER_STAKING_PROXY = 0x3D786C991452Cb7634D02b351374CB0aCC69fD71;

  /* ----- Tunables ----- */
  /// @dev AsterRewards fee rate (1e18 = 100%); capped at MAX_FEE_RATE = 3e17 (30%).
  uint256 constant FEE_RATE = 1e17; // 10%
  /// @dev Distributor pending-root time-lock; floor MIN_WAITING_PERIOD = 6h.
  uint256 constant DISTRIBUTOR_WAITING_PERIOD = 6 hours;

  /* ----- Final holders pre-wired at deploy (mirror deploy_lisaster_bsc) ----- */
  address constant PAUSER_ADDR = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
  address constant BOT_ADDR = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  address constant FEE_RECEIVER = 0x34B504A5CF0fF41F8A480580533b6Dda687fa3Da;

  function run() public {
    require(block.chainid == 56, "expect BSC mainnet (chainId 56)");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPk);

    address admin = deployer;
    address manager = deployer; // rotate via transfer_lisaster_roles_bsc afterwards
    address pauser = PAUSER_ADDR;
    address bot = BOT_ADDR;
    address feeReceiver = FEE_RECEIVER;

    console.log("Chain ID:        ", block.chainid);
    console.log("Deployer:        ", deployer);
    console.log("ASTER token:     ", ASTER_TOKEN);

    vm.startBroadcast(deployerPk);

    /* 1. Deploy both proxies with init data atomically baked into the constructor call so
     *    no init-front-run window exists between proxy CREATE and `initialize`. */
    bytes memory rewardsInit = abi.encodeCall(AsterRewards.initialize, (admin, pauser, manager, bot, ASTER_TOKEN));
    AsterRewards rewards = AsterRewards(address(new ERC1967Proxy(address(new AsterRewards()), rewardsInit)));

    bytes memory distributorInit = abi.encodeCall(
      LisAsterDistributor.initialize,
      LisAsterDistributor.InitParams({
        admin: admin,
        manager: manager,
        bot: bot,
        pauser: pauser,
        asterToken: ASTER_TOKEN,
        lisAster: LIS_ASTER_PROXY,
        vault: ASTER_VAULT_PROXY,
        staking: LIS_ASTER_STAKING_PROXY,
        rewards: address(rewards),
        waitingPeriod: DISTRIBUTOR_WAITING_PERIOD
      })
    );
    LisAsterDistributor distributor = LisAsterDistributor(
      address(new ERC1967Proxy(address(new LisAsterDistributor()), distributorInit))
    );

    /* 2. Rewards post-init wiring. All three calls are MANAGER-gated, so no front-run risk:
     *    only the deployer (current MANAGER) can call them.
     *    - one-shot setDistributor (breaks Rewards <-> Distributor circular dep)
     *    - fee config (receiver + rate). Both must be set; either being 0 disables the fee path.
     *      TODO: drop both calls if FEE_RATE = 0 desired at launch. */
    rewards.setDistributor(address(distributor));
    rewards.setFeeReceiver(feeReceiver);
    rewards.setFeeRate(FEE_RATE);

    vm.stopBroadcast();

    /* 4. Sanity assertions on critical post-deploy state. */
    require(rewards.distributor() == address(distributor), "Rewards.distributor not wired");
    require(distributor.rewards() == address(rewards), "Distributor.rewards mismatch");
    require(distributor.waitingPeriod() == DISTRIBUTOR_WAITING_PERIOD, "waitingPeriod mismatch");
    require(distributor.asterToken() == ASTER_TOKEN, "asterToken mismatch");
    require(distributor.lisAster() == LIS_ASTER_PROXY, "lisAster mismatch");
    require(distributor.vault() == ASTER_VAULT_PROXY, "vault mismatch");
    require(distributor.staking() == LIS_ASTER_STAKING_PROXY, "staking mismatch");

    console.log("---- New proxies ----");
    console.log("AsterRewards (v2):    ", address(rewards));
    console.log("LisAsterDistributor (v2):", address(distributor));
    console.log("---- Rewards fee ----");
    console.log("feeReceiver:        ", feeReceiver);
    console.log("feeRate (1e18=100%):", FEE_RATE);
    console.log("---- Roles ----");
    console.log("admin (deployer, rotate via transfer script):  ", deployer);
    console.log("manager (deployer, rotate via transfer script):", deployer);
    console.log("pauser:           ", pauser);
    console.log("bot:              ", bot);
  }
}
