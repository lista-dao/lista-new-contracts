// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { SlisBNBProvider } from "../../src/cdp/ceros/provider/SlisBNBProvider.sol";

/**
 * Deploys the new SlisBNBProvider implementation and prints the calldata for the cut-over
 * (see docs/slisbnb-provider-cdp-exit.md).
 *
 * forge script script/cdp/DeploySlisBNBProvider.s.sol:DeploySlisBNBProvider \
 *   --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <key> --broadcast --verify -vvv
 *
 * Env: DEPLOYER_PRIVATE_KEY, TIMELOCK_SALT (bytes32, next Changelog salt)
 */
contract DeploySlisBNBProvider is Script {
  address constant PROVIDER = 0xfD31e1C5e5571f8E7FE318f80888C1e6da97819b; // CDP SlisBNBProvider proxy
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  uint256 constant DELAY = 86400;

  function run() public {
    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    bytes32 salt = vm.envBytes32("TIMELOCK_SALT");

    vm.startBroadcast(pk);
    SlisBNBProvider impl = new SlisBNBProvider();
    vm.stopBroadcast();
    console.log("SlisBNBProvider impl:", address(impl));

    // Proposer Safe -> TimeLock: schedule / execute provider.upgradeToAndCall(impl, migrateFromCdp())
    bytes memory upgrade = abi.encodeWithSignature(
      "upgradeToAndCall(address,bytes)",
      address(impl),
      abi.encodeCall(SlisBNBProvider.migrateFromCdp, ())
    );
    bytes memory schedule = abi.encodeWithSignature(
      "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
      PROVIDER,
      0,
      upgrade,
      bytes32(0),
      salt,
      DELAY
    );
    bytes memory execute = abi.encodeWithSignature(
      "execute(address,uint256,bytes,bytes32,bytes32)",
      PROVIDER,
      0,
      upgrade,
      bytes32(0),
      salt
    );
    console.log("to TimeLock", TIMELOCK, "schedule data:");
    console.logBytes(schedule);
    console.log("to TimeLock (after delay), execute data:");
    console.logBytes(execute);
  }
}
