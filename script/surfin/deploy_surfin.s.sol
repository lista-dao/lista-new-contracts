// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/surfin/FlexEarnPool.sol";
import "../../src/surfin/LockedEarnPool.sol";
import "../../src/surfin/SurfinAdapter.sol";
import "../../src/surfin/InterestDistributor.sol";

/**
 * @dev Deploy the Surfin Credit Fund stack: FlexEarnPool + LockedEarnPool sharing
 *      one SurfinAdapter.
 *
 * The pool <-> adapter dependency is circular, so pools are initialized with the
 * deployer as a placeholder adapter, then rewired to the real adapter via
 * setAdapter once the adapter proxy exists.
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
  address public surfinWallet = 0x000000000000000000000000000000000000dEaD;

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

    // Implementations are inlined into the proxy constructors to keep run()'s local
    // variable count under the EVM stack limit (avoids "stack too deep").

    // 1. FlexEarnPool proxy (adapter placeholder = deployer)
    ERC1967Proxy flexProxy = new ERC1967Proxy(
      address(new FlexEarnPool()),
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

    // 2. LockedEarnPool proxy (adapter placeholder = deployer)
    ERC1967Proxy lockedProxy = new ERC1967Proxy(
      address(new LockedEarnPool()),
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

    // 3. SurfinAdapter proxy (real pool addresses + Surfin receiving wallet)
    ERC1967Proxy adapterProxy = new ERC1967Proxy(
      address(new SurfinAdapter(USDT)),
      abi.encodeWithSelector(
        SurfinAdapter.initialize.selector,
        admin,
        manager,
        pauser,
        bot,
        address(flexProxy),
        address(lockedProxy),
        surfinWallet
      )
    );

    // 4. rewire the real adapter into the pools
    FlexEarnPool(address(flexProxy)).setAdapter(address(adapterProxy));
    LockedEarnPool(address(lockedProxy)).setAdapter(address(adapterProxy));

    // 5. InterestDistributor proxy (funder = adapter; interest paid in USDT) + wiring
    ERC1967Proxy interestProxy = _deployInterestDistributor(admin, manager, bot, pauser, address(adapterProxy));
    SurfinAdapter(address(adapterProxy)).setInterestDistributor(address(interestProxy));

    vm.stopBroadcast();

    console.log("FlexEarnPool:   %s", address(flexProxy));
    console.log("LockedEarnPool: %s", address(lockedProxy));
    console.log("SurfinAdapter:  %s", address(adapterProxy));
    console.log("InterestDistributor: %s", address(interestProxy));
  }

  /// @dev deploy the InterestDistributor impl+proxy; split out of run() to keep the
  ///      stack shallow. `funder` is the adapter, the only address allowed to fund interest.
  function _deployInterestDistributor(
    address admin,
    address manager,
    address bot,
    address pauser,
    address funder
  ) internal returns (ERC1967Proxy interestProxy) {
    address[] memory interestTokens = new address[](1);
    interestTokens[0] = USDT;
    interestProxy = new ERC1967Proxy(
      address(new InterestDistributor()),
      abi.encodeWithSelector(
        InterestDistributor.initialize.selector,
        admin,
        manager,
        bot,
        pauser,
        funder,
        interestTokens
      )
    );
  }
}
