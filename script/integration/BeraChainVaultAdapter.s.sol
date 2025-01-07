// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/integration/BeraChainVaultAdapter.sol";

contract BeraChainVaultAdapterScript is Script {
  /**
   * @dev Run the script
   * mainnet:
   * forge script script/integration/BeraChainVaultAdapter.s.sol:BeraChainVaultAdapterScript --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <bscscan-api-key> --broadcast --verify -vvv
   *
   * testnet:
   * forge script script/integration/BeraChainVaultAdapter.s.sol:BeraChainVaultAdapterScript --broadcast --verify -vvv --rpc-url https://bsc-testnet.nodereal.io/v1/bced692b584d44908acb2e91f6e9d687 --etherscan-api-key <bscscan-api-key>
   * proxy: 0xa4143B44ecd54ce9B6827745568aEE9C9c167f6D
   */
  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: %s", deployer);
    address admin = vm.envOr("ADMIN", deployer);
    console.log("Admin: %s", admin);
    address manager = vm.envOr("MANAGER", deployer);
    console.log("Manager: %s", manager);
    address pauser = vm.envOr("PAUSER", deployer);
    console.log("Pauser: %s", pauser);
    address bot = vm.envOr("BOT", deployer);
    console.log("Bot: %s", bot);

    // FIXME: change to the correct address
    address BTCB = address(0x4BB2f2AA54c6663BFFD37b54eCd88eD81bC8B3ec); // for testnet
    console.log("Token: %s", BTCB);
    address lpToken = address(0x2d8645D3b8D2bAfd14ed4DCa4AD8D7D285D2fFe4); // for testnet
    console.log("LPToken: %s", lpToken);
    address botReceiver = address(0x05E3A7a66945ca9aF73f66660f22ffB36332FA54); // for testnet
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
