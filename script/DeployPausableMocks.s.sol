// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { PausableMock } from "../src/emergencySwitchHub/PausableMock.sol";

/**
 * @dev Deploy the full set of PausableMocks that stand in for the ETH core
 *      contracts, so the EmergencySwitchHub can be exercised on testnet.
 *      Mirrors the 9 contracts registered in the ETH (LIVE) runbook:
 *        Moolah, 6x StableSwapPool, XAUTStaking, ListaOFTv2.
 */
contract DeployPausableMocksScript is Script {
  /**
   * @dev Run the script
   * sepolia:
   * EMERGENCY_SWITCH_HUB=0x... \
   *   forge script script/DeployPausableMocks.s.sol --rpc-url <sepolia-rpc> --etherscan-api-key <etherscan-api-key> --broadcast --verify -vvv
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);
    address hub = vm.envAddress("EMERGENCY_SWITCH_HUB");
    console.log("EmergencySwitchHub: %s", hub);

    string[9] memory names = [
      "Moolah",
      "StableSwapPool-1",
      "StableSwapPool-2",
      "StableSwapPool-3",
      "StableSwapPool-4",
      "StableSwapPool-5",
      "StableSwapPool-6",
      "XAUTStaking",
      "ListaOFTv2"
    ];

    vm.startBroadcast(deployerPrivateKey);
    for (uint i = 0; i < names.length; i++) {
      PausableMock mock = new PausableMock(names[i], hub);
      console.log("PausableMock [%s]: %s", names[i], address(mock));
    }
    vm.stopBroadcast();
  }
}
