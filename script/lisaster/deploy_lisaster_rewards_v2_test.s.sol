// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { AsterRewards } from "../../src/lisaster/AsterRewards.sol";
import { LisAsterDistributor } from "../../src/lisaster/LisAsterDistributor.sol";

/// @title DeployLisAsterRewardsV2Testnet
/// @notice BSC testnet migration deploy: provisions the new ASTER-denominated AsterRewards +
///         LisAsterDistributor proxies and wires them against the existing testnet
///         LisAster / AsterVault / LisAsterStaking proxies. The previous Rewards / Distributor
///         proxies are abandoned (operationally paused; this script does not touch them).
///
///         All roles default to the deployer for ease of iteration. Fee config matches the
///         original testnet deploy (10% to deployer).
///
///         Run: forge script script/lisaster/deploy_lisaster_rewards_v2_test.s.sol:DeployLisAsterRewardsV2Testnet \
///                 --rpc-url bsc_testnet --broadcast --verify -vvvv
contract DeployLisAsterRewardsV2Testnet is Script {
  /* BSC testnet (chainId 97) externals */
  address constant ASTER_TOKEN = 0xB6c2c7773F08690Ac16971b84f003a92f6DcB705;

  /* Retained testnet proxies */
  address constant LIS_ASTER_PROXY = 0x7d11A842FFfe6Bbfd530E3cA316be2A2B1DB1dd2;
  address constant ASTER_VAULT_PROXY = 0x875074d2560e5061528d9F3fF25eb002121c9C3B;
  address constant LIS_ASTER_STAKING_PROXY = 0x41A31195B7d071dC42168baa941177C96e0f1f3E;

  /* Tunables */
  /// @dev AsterRewards fee rate (1e18 = 100%). Capped at MAX_FEE_RATE = 3e17 (30%).
  uint256 constant FEE_RATE = 1e17; // 10%
  /// @dev Distributor pending-root time-lock for fast testnet iteration.
  ///      NOTE: src `MIN_WAITING_PERIOD` is the mainnet 6h floor; to re-run this script you must
  ///      temporarily lower the constant to <= 5 minutes (do NOT ship that change to mainnet).
  ///      The currently live testnet Distributor already carries waitingPeriod = 300s.
  uint256 constant DISTRIBUTOR_WAITING_PERIOD = 5 minutes;

  function run() public {
    require(block.chainid == 97, "expect BSC testnet (chainId 97)");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPk);

    // All roles default to deployer on testnet; rotate later via grantRole if needed.
    address admin = deployer;
    address pauser = deployer;
    address manager = deployer;
    address bot = deployer;
    address feeReceiver = deployer;

    console.log("Chain ID:        ", block.chainid);
    console.log("Deployer:        ", deployer);
    console.log("ASTER token:     ", ASTER_TOKEN);

    vm.startBroadcast(deployerPk);

    /* 1. Atomic init: bake initialize calldata into proxy CREATE so attackers cannot
     *    front-run a separate `initialize` tx. */
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

    /* 2. Rewards post-init wiring -- MANAGER-gated, no front-run risk.
     *    - one-shot setDistributor
     *    - fee config (receiver + rate) */
    rewards.setDistributor(address(distributor));
    rewards.setFeeReceiver(feeReceiver);
    rewards.setFeeRate(FEE_RATE);

    vm.stopBroadcast();

    /* 4. Sanity asserts. */
    require(rewards.distributor() == address(distributor), "Rewards.distributor not wired");
    require(distributor.rewards() == address(rewards), "Distributor.rewards mismatch");
    require(distributor.waitingPeriod() == DISTRIBUTOR_WAITING_PERIOD, "waitingPeriod mismatch");
    require(distributor.asterToken() == ASTER_TOKEN, "asterToken mismatch");
    require(distributor.lisAster() == LIS_ASTER_PROXY, "lisAster mismatch");
    require(distributor.vault() == ASTER_VAULT_PROXY, "vault mismatch");
    require(distributor.staking() == LIS_ASTER_STAKING_PROXY, "staking mismatch");

    console.log("---- New proxies ----");
    console.log("AsterRewards (v2):       ", address(rewards));
    console.log("LisAsterDistributor (v2):", address(distributor));
    console.log("---- Config ----");
    console.log("feeReceiver:             ", feeReceiver);
    console.log("feeRate (1e18=100%):     ", FEE_RATE);
    console.log("waitingPeriod (s):       ", DISTRIBUTOR_WAITING_PERIOD);
  }
}
