// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { PausableMock } from "../src/emergencySwitchHub/PausableMock.sol";

contract DeployPausableMockScript is Script {
  string[] names = ["MockLending", "MockCDP", "MockStaking"];
  address emergencySwitchHub = 0x0000000000000000000000000000000000000000;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);

    vm.startBroadcast(deployerPrivateKey);
    for (uint i = 0; i < names.length; i++) {
      PausableMock _mock = new PausableMock(names[i], emergencySwitchHub);
      console2.log("Deployed PausableMock:", address(_mock));
    }

    vm.stopBroadcast();
  }
}
