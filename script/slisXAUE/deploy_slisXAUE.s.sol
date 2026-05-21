// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/slisXAUE/SlisXAUE.sol";
import "../../src/slisXAUE/XAUTStaking.sol";
import "../../src/slisXAUE/XAUEAdapter.sol";

/**
 * @title DeploySlisXAUE
 * @notice Deploys SlisXAUE + XAUTStaking + XAUEAdapter on Sepolia, wires up MINTER,
 *         and sets initial parameters (feeRate=20%, mintCap=15K, minDeposit=1000, etc.).
 *
 * @dev Sepolia XAUE testnet addresses (deployer 0x6616EF47...4f06):
 *      MockXAUT:  0x1467CF3bda74b1811B93cf66CdE24F81a241FCe2 (6 dec)
 *      Oracle:    0x3426cde40982a9D44d5ec0Cf76ea616260820c35
 *      FundToken: 0x65E9d3cf590814bFE2C5E4e29914e27722733363
 *      Vault:     0x94F05b43c00387a1D7CA3E4791FC2597082Ef8B6
 *
 *      Lista contracts (XAUEAdapter) must be whitelisted on the XAUE FundToken before any
 *      mint/redeem will succeed. Use the deployer EOA (which is XAUE's MANAGER on Sepolia)
 *      to call addToWhitelist(adapter) after deploying.
 */
contract DeploySlisXAUE is Script {
  // Sepolia XAUE testnet
  address public constant XAUT = 0x1467CF3bda74b1811B93cf66CdE24F81a241FCe2;
  address public constant XAUE_FUND_TOKEN = 0x65E9d3cf590814bFE2C5E4e29914e27722733363;
  address public constant XAUE_ORACLE = 0x3426cde40982a9D44d5ec0Cf76ea616260820c35;

  // Initial parameters
  uint256 public constant MINT_CAP = 15_000 * 1e18; // 15K slisXAUE
  uint256 public constant FEE_RATE = 0.2e18; // 20%
  uint256 public constant MIN_DEPOSIT = 1000; // 0.001 XAUT (matches XAUE.minDepositAmount; Staking-side gate)
  uint256 public constant MIN_WITHDRAW = 1000; // 0.001 XAUT; equals the XAUT-equivalent of XAUE.minRedeemShares at baseNAV

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);

    // For Sepolia testing, deployer holds admin / manager / pauser / bot. On mainnet, use a multisig.
    address admin = deployer;
    address manager = deployer;
    address pauser = deployer;
    address bot = deployer;
    address feeReceiver = deployer;

    vm.startBroadcast(deployerPrivateKey);

    // 1) Deploy implementations
    SlisXAUE slisImpl = new SlisXAUE();
    XAUTStaking stakingImpl = new XAUTStaking();
    XAUEAdapter adapterImpl = new XAUEAdapter(XAUT);

    // 2) Deploy proxies (uninitialized — we initialize them with cross-references below)
    SlisXAUE slisXAUE = SlisXAUE(address(new ERC1967Proxy(address(slisImpl), "")));
    XAUTStaking staking = XAUTStaking(address(new ERC1967Proxy(address(stakingImpl), "")));
    XAUEAdapter adapter = XAUEAdapter(address(new ERC1967Proxy(address(adapterImpl), "")));

    // 3) Initialize. SlisXAUE grants MINTER to staking at init time.
    slisXAUE.initialize(admin, address(staking), "Lista Staked XAUE", "slisXAUE");
    staking.initialize(admin, manager, pauser, XAUT, address(slisXAUE), address(adapter), MINT_CAP);
    adapter.initialize(admin, manager, bot, address(staking), XAUE_FUND_TOKEN, XAUE_ORACLE);

    // 4) Set adapter parameters
    adapter.setFeeReceiver(feeReceiver);
    adapter.setFeeRate(FEE_RATE);

    // 5) Set staking parameters
    staking.setMinDeposit(MIN_DEPOSIT);
    staking.setMinWithdraw(MIN_WITHDRAW);
    // mintCap is already set at init

    vm.stopBroadcast();

    console.log("=============================================");
    console.log("slisXAUE deployment on Sepolia");
    console.log("=============================================");
    console.log("SlisXAUE impl:    ", address(slisImpl));
    console.log("SlisXAUE proxy:   ", address(slisXAUE));
    console.log("XAUTStaking impl:  ", address(stakingImpl));
    console.log("XAUTStaking proxy: ", address(staking));
    console.log("XAUEAdapter impl: ", address(adapterImpl));
    console.log("XAUEAdapter proxy:", address(adapter));
    console.log("---------------------------------------------");
    console.log("Next step: whitelist XAUEAdapter on XAUE FundToken:");
    console.log("  cast send", XAUE_FUND_TOKEN, '"addToWhitelist(address)"', address(adapter));
    console.log("=============================================");
  }
}
