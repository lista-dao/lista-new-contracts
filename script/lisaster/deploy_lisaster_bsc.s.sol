// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LisAster } from "../../src/lisaster/LisAster.sol";
import { AsterVault } from "../../src/lisaster/AsterVault.sol";
import { LisAsterStaking } from "../../src/lisaster/LisAsterStaking.sol";
import { LisAsterRewards } from "../../src/lisaster/LisAsterRewards.sol";
import { LisAsterDistributor } from "../../src/lisaster/LisAsterDistributor.sol";

/// @title DeployLisAsterBsc
/// @notice One-shot BSC mainnet deploy: 5 proxies + initialize + Rewards wiring
///         (distributor + feeReceiver + feeRate).
///
///         ALL operational roles (DEFAULT_ADMIN / PAUSER / MANAGER / BOT / lisAsterManager /
///         feeReceiver) are kept on the deployer EOA. Use the companion script
///         `transfer_lisaster_roles_bsc.s.sol` AFTER on-chain verification to rotate them to
///         the production multisigs / EOAs.
///
///         Run: forge script script/lisaster/deploy_lisaster_bsc.s.sol:DeployLisAsterBsc \
///                 --rpc-url bsc --broadcast --verify -vvvv
contract DeployLisAsterBsc is Script {
  /* ----- BSC mainnet (chainId 56) external addresses ----- */
  /// @dev BSC mainnet ASTER ERC20.
  address constant ASTER_TOKEN = 0x000Ae314E2A2172a039B26378814C252734f556A;
  /// @dev AstherusVault BSC mainnet UUPS proxy (see lisAster/02 docs).
  address constant ASTHERUS_VAULT = 0x128463A60784c4D3f46c23Af3f65Ed859Ba87974;

  /* ----- Tunables (mainnet defaults; review before broadcast) ----- */
  /// @dev 4th arg to AstherusVault.depositFor. Lista default = 1.
  uint256 constant BROKER = 1;
  /// @dev Minimum AsterVault.deposit amount (ASTER, 18 decimals). 0.1 ASTER.
  uint256 constant MIN_DEPOSIT = 0.1 ether;
  /// @dev LisAsterRewards fee rate (1e18 = 100%). Capped at MAX_FEE_RATE = 3e17 (30%).
  ///      TODO: confirm production fee rate with ops before broadcast.
  uint256 constant FEE_RATE = 1e17; // 10%
  /// @dev LisAsterDistributor pending-root time-lock. Hard floor MIN_WAITING_PERIOD = 6h.
  uint256 constant DISTRIBUTOR_WAITING_PERIOD = 6 hours;

  /* ----- Final role holders that are safe to wire at deploy time -----
   *      DEFAULT_ADMIN and MANAGER stay on the deployer until the post-deploy
   *      verification step; rotated by transfer_lisaster_roles_bsc.s.sol. */
  address constant PAUSER_ADDR = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
  /// @dev Rewards.BOT (distributeRewards keeper) + Distributor.BOT (stage/accept Merkle root).
  address constant BOT_ADDR = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  /// @dev forAddress passed to AstherusVault.depositFor — Lista-operated EOA mirrored on Aster Chain.
  address constant LIS_ASTER_MANAGER = 0x7ae0D99f5F7BF89282d28eE013BBb6e19fCb76cB;
  /// @dev ASTER fee recipient inside LisAsterRewards.notifyRewards.
  address constant FEE_RECEIVER = 0x34B504A5CF0fF41F8A480580533b6Dda687fa3Da;

  function run() public {
    require(block.chainid == 56, "expect BSC mainnet (chainId 56)");

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPk);

    /* ----- Roles -----
     *  Retained by deployer (rotated via transfer_lisaster_roles_bsc.s.sol after verification):
     *    - DEFAULT_ADMIN on all 5 proxies
     *    - Vault / Staking / Rewards / Distributor MANAGER (Rewards MANAGER == ops MANAGER)
     *  Wired to final holders right here (low-risk, no post-deploy rotation needed):
     *    - PAUSER / BOT / lisAsterManager / feeReceiver */
    address admin = deployer;
    address manager = deployer; // includes Rewards.MANAGER per ops decision (single multisig)
    address pauser = PAUSER_ADDR;
    address bot = BOT_ADDR;
    address lisAsterManager = LIS_ASTER_MANAGER;
    address feeReceiver = FEE_RECEIVER;

    console.log("Chain ID:        ", block.chainid);
    console.log("Deployer:        ", deployer);
    console.log("ASTER token:     ", ASTER_TOKEN);
    console.log("AstherusVault:   ", ASTHERUS_VAULT);

    vm.startBroadcast(deployerPk);

    /* 1. Deploy 5 proxies (no init) so the addresses are known up front. */
    LisAster lisAster = LisAster(address(new ERC1967Proxy(address(new LisAster()), "")));
    AsterVault vault = AsterVault(address(new ERC1967Proxy(address(new AsterVault()), "")));
    LisAsterStaking staking = LisAsterStaking(address(new ERC1967Proxy(address(new LisAsterStaking()), "")));
    LisAsterRewards rewards = LisAsterRewards(address(new ERC1967Proxy(address(new LisAsterRewards()), "")));
    LisAsterDistributor distributor = LisAsterDistributor(
      address(new ERC1967Proxy(address(new LisAsterDistributor()), ""))
    );

    /* 2. Initialize in dependency order. All required roles land inside each init. */
    lisAster.initialize(admin, address(vault), "Lista Staked Aster", "lisAster");

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

    rewards.initialize(admin, pauser, manager, bot, ASTER_TOKEN, address(lisAster), address(vault));

    distributor.initialize(
      admin,
      manager,
      bot,
      pauser,
      address(lisAster),
      address(staking),
      address(rewards),
      DISTRIBUTOR_WAITING_PERIOD
    );

    /* 3. Rewards post-init wiring (deployer holds Rewards.MANAGER at this point):
     *    - one-shot setDistributor (breaks Rewards <-> Distributor circular dependency)
     *    - fee config (receiver + rate). Both must be set; either being 0 disables the fee path.
     *      TODO: if FEE_RATE = 0 desired at launch, drop setFeeRate + setFeeReceiver calls. */
    rewards.setDistributor(address(distributor));
    rewards.setFeeReceiver(feeReceiver);
    rewards.setFeeRate(FEE_RATE);

    vm.stopBroadcast();

    /* 4. Sanity assertions on critical invariants before printing. */
    require(lisAster.hasRole(lisAster.MINTER(), address(vault)), "MINTER != vault");
    require(rewards.distributor() == address(distributor), "Rewards.distributor not wired");
    require(distributor.waitingPeriod() == DISTRIBUTOR_WAITING_PERIOD, "waitingPeriod mismatch");

    console.log("---- Proxies ----");
    console.log("LisAster:            ", address(lisAster));
    console.log("AsterVault:          ", address(vault));
    console.log("LisAsterStaking:     ", address(staking));
    console.log("LisAsterRewards:     ", address(rewards));
    console.log("LisAsterDistributor: ", address(distributor));
    console.log("---- Rewards fee ----");
    console.log("feeReceiver:         ", feeReceiver);
    console.log("feeRate (1e18=100%): ", FEE_RATE);
    console.log("---- Roles ----");
    console.log("admin (deployer, rotate via transfer script): ", deployer);
    console.log("manager (deployer, rotate via transfer script):", deployer);
    console.log("pauser:           ", pauser);
    console.log("bot:              ", bot);
    console.log("lisAsterManager:  ", lisAsterManager);
    console.log("feeReceiver:      ", feeReceiver);
  }
}
