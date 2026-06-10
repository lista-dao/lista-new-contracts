// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/slisXAUE/SlisXAUE.sol";
import "../../src/slisXAUE/XAUTStaking.sol";
import "../../src/slisXAUE/XAUEAdapter.sol";

/**
 * @title DeploySlisXAUEMainnet
 * @notice Ethereum mainnet deploy of SlisXAUE + XAUTStaking + XAUEAdapter (atomic init), wiring
 *         adapter->staking and setting min deposit/withdraw. Must be run from the FINAL audited
 *         commit (Bailsec fixes, PR #33) — see the launch runbook.
 *
 * @dev External XAUE mainnet addresses (confirmed on-chain 2026-06-08):
 *      XAUt (Tether Gold, 6-dec): 0x68749665FF8D2d112Fa859AA293F07A622782F38
 *      FundToken (CoboFundToken, 18-dec): 0xd5D6840ed95F58FAf537865DcA15D5f99195F87a
 *        - asset() == XAUt, oracle() == Oracle below (verified)
 *      Oracle (CoboFundOracle, NAV 1e18-scaled, monotonic non-decreasing): 0x0618BD112C396060d2b37B537b3d92e757644169
 *
 *      admin & manager are the DEPLOYER (temporary) — handed to the 24h TimeLock (admin) and the
 *      MANAGER multisig in deploy_slisXAUE_transferRole.s.sol after deploy + seed. pauser / bot /
 *      feeReceiver are set to their FINAL addresses at init.
 *
 *      Post-deploy (runbook): (1) XAUE whitelists the adapter on the FundToken; (2) permanent
 *      governance seed deposit (deployer deposit -> BOT depositToVault); (3) transfer roles.
 */
contract DeploySlisXAUEMainnet is Script {
  // --- External XAUE mainnet ---
  address public constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
  address public constant XAUE_FUND_TOKEN = 0xd5D6840ed95F58FAf537865DcA15D5f99195F87a;
  address public constant XAUE_ORACLE = 0x0618BD112C396060d2b37B537b3d92e757644169;

  // --- Final role holders (set at init) ---
  address public constant BOT = 0x91fC4BA20685339781888eCA3E9E1c12d40F0e13;
  address public constant PAUSER = 0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8;
  address public constant FEE_RECEIVER = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  // --- Initial parameters ---
  uint256 public constant MINT_CAP = 15_000 * 1e18; // 15K slisXAUE (~15K XAUt cap; MANAGER-tunable)
  uint256 public constant FEE_RATE = 0.2e18; // 20% on NAV profit (<= MAX_FEE_RATE 30%)
  uint256 public constant MIN_DEPOSIT = 30_000; // 0.03 XAUt (6-dec); >> FundToken.minDepositAmount (1000)
  uint256 public constant MIN_WITHDRAW = 10_000; // 0.01 XAUt (6-dec); ~10x the live redeem floor (~0.001 XAUt)
  string public constant NAME = "Staked Lista XAUE";
  string public constant SYMBOL = "slisXAUE";

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);

    // admin / manager: deployer holds both TEMPORARILY, handed over in the transferRole step.
    address admin = deployer;
    address manager = deployer;

    vm.startBroadcast(deployerPrivateKey);

    // 1) Implementations
    SlisXAUE slisImpl = new SlisXAUE();
    XAUTStaking stakingImpl = new XAUTStaking();
    XAUEAdapter adapterImpl = new XAUEAdapter(XAUT);

    // 2) Proxies in dependency order, each ATOMICALLY initialized in its ERC1967Proxy constructor
    //    (no separate front-runnable init tx; audit M-01). Addresses captured directly -- no nonce
    //    prediction. slisXAUE.initialize takes no minter; MINTER is granted to staking in step 3
    //    (breaks the slisXAUE <-> staking cycle), and adapter -> staking is wired via setStaking.
    address slisXaueProxy = address(
      new ERC1967Proxy(address(slisImpl), abi.encodeCall(SlisXAUE.initialize, (admin, NAME, SYMBOL)))
    );
    address adapterProxy = address(
      new ERC1967Proxy(
        address(adapterImpl),
        abi.encodeCall(
          XAUEAdapter.initialize,
          (admin, manager, BOT, slisXaueProxy, XAUE_FUND_TOKEN, XAUE_ORACLE, FEE_RECEIVER, FEE_RATE)
        )
      )
    );
    address stakingProxy = address(
      new ERC1967Proxy(
        address(stakingImpl),
        abi.encodeCall(XAUTStaking.initialize, (admin, manager, PAUSER, XAUT, slisXaueProxy, adapterProxy, MINT_CAP))
      )
    );

    SlisXAUE slisXAUE = SlisXAUE(slisXaueProxy);
    XAUEAdapter adapter = XAUEAdapter(adapterProxy);
    XAUTStaking staking = XAUTStaking(stakingProxy);

    // 3) Wire cross-refs (deployer holds admin + manager here): adapter -> staking, grant MINTER to
    //    staking, then set the min deposit/withdraw thresholds (mintCap set at init).
    adapter.setStaking(stakingProxy);
    slisXAUE.grantRole(slisXAUE.MINTER(), stakingProxy);
    staking.setMinDeposit(MIN_DEPOSIT);
    staking.setMinWithdraw(MIN_WITHDRAW);

    vm.stopBroadcast();

    console.log("=============================================");
    console.log("slisXAUE deployment on Ethereum mainnet");
    console.log("=============================================");
    console.log("SlisXAUE impl:    ", address(slisImpl));
    console.log("SlisXAUE proxy:   ", slisXaueProxy);
    console.log("XAUTStaking impl: ", address(stakingImpl));
    console.log("XAUTStaking proxy:", stakingProxy);
    console.log("XAUEAdapter impl: ", address(adapterImpl));
    console.log("XAUEAdapter proxy:", adapterProxy);
    console.log("---------------------------------------------");
    console.log("Next (runbook): 1) XAUE addToWhitelist(adapter) on FundToken;");
    console.log("                2) seed deposit (deployer deposit -> BOT depositToVault);");
    console.log("                3) deploy_slisXAUE_transferRole.s.sol (admin->TimeLock, manager->multisig).");
    console.log("=============================================");
  }
}
