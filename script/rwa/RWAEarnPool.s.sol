// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/rwa/RWAEarnPool.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RWAEarnPoolDeploy is Script {
  address USD1 = 0x0e82c3284a5a957279dF552269f1808C712caC34;
  address USDC = 0x3aaaa86458d576BafCB1B7eD290434F0696dA65c;
  address vault = 0xC2b55783609f5219cfC13FF31f960b6C7027241b;
  address shareToken = 0xABC226faDdC07d81C975Efa7C6b3F45f57782551;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);

    RWAEarnPool impl = new RWAEarnPool();

    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, deployer, deployer, deployer, vault, shareToken)
    );

    vm.stopBroadcast();
  }
}
