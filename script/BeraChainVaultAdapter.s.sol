// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/BeraChainVaultAdapter.sol";

contract BeraChainVaultAdapterScript is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/BeraChainVaultAdapter.s.sol:BeraChainVaultAdapterScript --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/BeraChainVaultAdapter.s.sol:BeraChainVaultAdapterScript --broadcast --verify -vvv --rpc-url https://bsc-testnet.nodereal.io/v1/bced692b584d44908acb2e91f6e9d687 --etherscan-api-key <bscscan-api-key>
   * proxy: 0x493171878Ca4C37984Fe54Aa0491E5E0098D78FC
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);
    address admin = vm.envOr("ADMIN", deployer);
    console.log("Admin: %s", admin);
    address manager = address(0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66);
    console.log("Manager: %s", manager);
    address pauser = address(0xEEfebb1546d88EA0909435DF6f615084DD3c5Bd8);
    console.log("Pauser: %s", pauser);
    address bot = address(0x91fC4BA20685339781888eCA3E9E1c12d40F0e13);
    console.log("Bot: %s", bot);

    // FIXME: change to the correct address
    address BTCB = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    console.log("Token: %s", BTCB);
    address lpToken = address(0x0000000000000000000000000000000000000000); // TODO:
    console.log("LPToken: %s", lpToken);
    address botReceiver = address(0x1d60bBBEF79Fb9540D271Dbb01925380323A8f66);
    console.log("BotReceiver: %s", botReceiver);

    vm.startBroadcast(deployerPrivateKey);
    BeraChainVaultAdapter impl = new BeraChainVaultAdapter();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeCall(impl.initialize, (admin, manager, pauser, bot, BTCB, lpToken, botReceiver, 1738368000))
    );
    // 1738368000 is 2025-02-01 00:00:00 utc+0
    vm.stopBroadcast();
    console.log("BeraChainVaultAdapter address: %s", address(proxy));
    console.log("BeraChainVaultAdapter impl: %s", address(impl));
  }
}
