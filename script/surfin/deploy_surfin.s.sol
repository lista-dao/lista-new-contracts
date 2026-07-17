// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/surfin/FlexEarnPool.sol";
import "../../src/surfin/LockedEarnPool.sol";
import "../../src/surfin/SurfinAdapter.sol";
import "../../src/surfin/OTCManager.sol";

/**
 * @dev Deploy the Surfin Credit Fund stack: FlexEarnPool + LockedEarnPool sharing
 *      one SurfinAdapter, plus the OTCManager gateway to Surfin.
 *
 * The pool <-> adapter dependency is circular, so pools and the OTC manager are
 * initialized with the deployer as a placeholder adapter, then rewired to the real
 * adapter via setAdapter once the adapter proxy exists.
 *
 * Usage:
 * DEPLOYER_PRIVATE_KEY=<key> BSCSCAN_API_KEY=<key> \
 *   forge script script/surfin/deploy_surfin.s.sol:DeploySurfin \
 *   --rpc-url https://bsc-dataseed.binance.org --broadcast --verify -vvv
 */
contract DeploySurfin is Script {
  // BSC Mainnet USDT
  address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;

  // Surfin receiving multisig — REPLACE before mainnet deploy
  address public otcWallet = 0x000000000000000000000000000000000000dEaD;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    // roles default to deployer; rotate to multisig/TimeLock after deploy
    address admin = deployer;
    address manager = deployer;
    address pauser = deployer;
    address bot = deployer;

    vm.startBroadcast(deployerPrivateKey);

    // 1. implementations
    FlexEarnPool flexImpl = new FlexEarnPool();
    LockedEarnPool lockedImpl = new LockedEarnPool();
    SurfinAdapter adapterImpl = new SurfinAdapter(USDT);
    OTCManager otcImpl = new OTCManager(USDT);

    // 2. OTCManager proxy (adapter placeholder = deployer)
    ERC1967Proxy otcProxy = new ERC1967Proxy(
      address(otcImpl),
      abi.encodeWithSelector(OTCManager.initialize.selector, admin, manager, bot, deployer, otcWallet)
    );

    // 3. FlexEarnPool proxy (adapter placeholder = deployer)
    ERC1967Proxy flexProxy = new ERC1967Proxy(
      address(flexImpl),
      abi.encodeWithSelector(
        FlexEarnPool.initialize.selector,
        admin,
        manager,
        pauser,
        bot,
        USDT,
        deployer,
        "Surfin Flex USDT",
        "sfUSDT"
      )
    );

    // 4. LockedEarnPool proxy (adapter placeholder = deployer)
    ERC1967Proxy lockedProxy = new ERC1967Proxy(
      address(lockedImpl),
      abi.encodeWithSelector(
        LockedEarnPool.initialize.selector,
        admin,
        manager,
        pauser,
        bot,
        USDT,
        deployer,
        "Surfin Locked USDT",
        "slUSDT"
      )
    );

    // 5. SurfinAdapter proxy (real pool + otc addresses)
    ERC1967Proxy adapterProxy = new ERC1967Proxy(
      address(adapterImpl),
      abi.encodeWithSelector(
        SurfinAdapter.initialize.selector,
        admin,
        manager,
        bot,
        address(flexProxy),
        address(lockedProxy),
        address(otcProxy)
      )
    );

    // 6. rewire the real adapter into the pools and the OTC manager
    FlexEarnPool(address(flexProxy)).setAdapter(address(adapterProxy));
    LockedEarnPool(address(lockedProxy)).setAdapter(address(adapterProxy));
    OTCManager(address(otcProxy)).setAdapter(address(adapterProxy));

    vm.stopBroadcast();

    console.log("FlexEarnPool:   %s", address(flexProxy));
    console.log("LockedEarnPool: %s", address(lockedProxy));
    console.log("SurfinAdapter:  %s", address(adapterProxy));
    console.log("OTCManager:     %s", address(otcProxy));
  }
}
