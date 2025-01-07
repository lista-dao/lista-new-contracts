// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/token/NonTransferableLpERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import "forge-std/Test.sol";

contract BTCBLPScript is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/token/BTCBLP.s.sol:BTCBLPScript --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/token/BTCBLP.s.sol:BTCBLPScript --broadcast --verify -vvv --rpc-url https://bsc-testnet.nodereal.io/v1/bced692b584d44908acb2e91f6e9d687 --etherscan-api-key <bscscan-api-key>
   * proxy: 0x2d8645D3b8D2bAfd14ed4DCa4AD8D7D285D2fFe4
   * impl: 0x700913b4bc4d6443f8c5536d40814d66a3fd3635
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);

    vm.startBroadcast(deployerPrivateKey);
    NonTransferableLpERC20 impl = new NonTransferableLpERC20();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeCall(impl.initialize, ("Lista Berachain BTCB LP", "clis-BTCBLP"))
    );
    vm.stopBroadcast();

    console.log("BTCBLP address: %s", address(proxy));
    console.log("BTCBLP impl: %s", address(impl));
  }
}
