// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LisAster } from "../../src/lisaster/LisAster.sol";
import { AsterVault } from "../../src/lisaster/AsterVault.sol";
import { LisAsterStaking } from "../../src/lisaster/LisAsterStaking.sol";
import { LisAsterRewards } from "../../src/lisaster/LisAsterRewards.sol";
import { LisAsterDistributor } from "../../src/lisaster/LisAsterDistributor.sol";

/// @title DeployLisAsterTestnet
/// @notice One-shot BSC testnet deploy: 5 proxies + initialize + Rewards wiring (distributor +
///         feeReceiver + feeRate).
///         All roles (admin / pauser / manager / bot / lisAsterManager / feeReceiver) default
///         to deployer.
///         Run: forge script script/lisaster/deploy_lisaster_test.sol:DeployLisAsterTestnet \
///                 --rpc-url bsc_testnet --broadcast --verify -vvvv
contract DeployLisAsterTestnet is Script {
  /* BSC testnet (chainId 97) constants */
  address constant ASTER_TOKEN = 0xB6c2c7773F08690Ac16971b84f003a92f6DcB705;
  address constant ASTHERUS_VAULT = 0x62904590b575ea1C3F4aC411EB6A5A3140d6956e;

  uint256 constant BROKER = 1;
  uint256 constant MIN_DEPOSIT = 0.1 ether;

  /// @dev Reward fee on testnet. 1e18 = 100%, capped at MAX_FEE_RATE (3e17 = 30%).
  uint256 constant FEE_RATE = 1e17; // 10%

  /// @dev Distributor pending-root time-lock window (BOT stages -> wait -> BOT accepts).
  ///      Must be >= LisAsterDistributor.MIN_WAITING_PERIOD (6 hours).
  uint256 constant DISTRIBUTOR_WAITING_PERIOD = 6 hours;

  function run() public {
    require(block.chainid == 97, "expect BSC testnet (chainId 97)");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPk);

    console.log("Chain ID:        ", block.chainid);
    console.log("Deployer:        ", deployer);
    console.log("ASTER token:     ", ASTER_TOKEN);
    console.log("AstherusVault:   ", ASTHERUS_VAULT);

    // All roles default to deployer on testnet; rotate later via grantRole / setBroker etc.
    address admin = deployer;
    address pauser = deployer;
    address manager = deployer; // Distributor MANAGER (revokes pending Merkle root, emergency withdraw)
    address rewardsManager = deployer; // Rewards.MANAGER (notifyRewards EOA, also calls setDistributor / fee setters)
    address bot = deployer; // Rewards.BOT (distributeRewards keeper) and Distributor.BOT (stages + accepts pending root)
    address lisAsterManager = deployer; // forAddress in AstherusVault.depositFor
    address feeReceiver = deployer; // ASTER fee recipient on Rewards.notifyRewards

    vm.startBroadcast(deployerPk);

    /* 1. Deploy 5 proxies (no init) so addresses are known up front. */
    LisAster lisAster = LisAster(address(new ERC1967Proxy(address(new LisAster()), "")));
    AsterVault vault = AsterVault(address(new ERC1967Proxy(address(new AsterVault()), "")));
    LisAsterStaking staking = LisAsterStaking(address(new ERC1967Proxy(address(new LisAsterStaking()), "")));
    LisAsterRewards rewards = LisAsterRewards(address(new ERC1967Proxy(address(new LisAsterRewards()), "")));
    LisAsterDistributor distributor = LisAsterDistributor(
      address(new ERC1967Proxy(address(new LisAsterDistributor()), ""))
    );

    /* 2. Initialize in dependency order. All required roles land inside each init. */
    lisAster.initialize(admin, address(vault), "Lista Aster", "lisAster");

    vault.initialize(
      admin,
      pauser,
      manager,
      ASTER_TOKEN,
      ASTHERUS_VAULT,
      address(lisAster),
      lisAsterManager,
      BROKER,
      MIN_DEPOSIT
    );

    staking.initialize(admin, pauser, manager, address(lisAster));

    rewards.initialize(admin, pauser, rewardsManager, bot, ASTER_TOKEN);

    distributor.initialize(
      LisAsterDistributor.InitParams({
        admin: admin,
        manager: manager,
        bot: bot,
        pauser: pauser,
        asterToken: ASTER_TOKEN,
        lisAster: address(lisAster),
        vault: address(vault),
        staking: address(staking),
        rewards: address(rewards),
        waitingPeriod: DISTRIBUTOR_WAITING_PERIOD
      })
    );

    /* 3. Rewards post-init wiring (deployer holds Rewards.MANAGER on testnet):
     *    - one-shot setDistributor
     *    - fee config (receiver + rate). Both must be set; either being 0 disables the fee path. */
    rewards.setDistributor(address(distributor));
    rewards.setFeeReceiver(feeReceiver);
    rewards.setFeeRate(FEE_RATE);

    vm.stopBroadcast();

    console.log("---- Proxies ----");
    console.log("LisAster:            ", address(lisAster));
    console.log("AsterVault:          ", address(vault));
    console.log("LisAsterStaking:     ", address(staking));
    console.log("LisAsterRewards:     ", address(rewards));
    console.log("LisAsterDistributor: ", address(distributor));
    console.log("---- Rewards fee ----");
    console.log("feeReceiver:         ", feeReceiver);
    console.log("feeRate (1e18=100%): ", FEE_RATE);
  }
}
