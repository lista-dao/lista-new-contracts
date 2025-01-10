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
    address manager = vm.envOr("MANAGER", deployer);
    console.log("Manager: %s", manager);
    address pauser = vm.envOr("PAUSER", deployer);
    console.log("Pauser: %s", pauser);
    address bot = vm.envOr("BOT", deployer);
    console.log("Bot: %s", bot);

    address BTCB = vm.envOr("BTCB_TOKEN", deployer);
    console.log("Token: %s", BTCB);
    address lpToken = vm.envOr("BTCB_LP_TOKEN", deployer);
    console.log("LPToken: %s", lpToken);
    address botReceiver = vm.envOr("BTCB_VAULT_OPERATOR", deployer);
    console.log("BotReceiver: %s", botReceiver);
    uint256 depositEndTime = vm.envOr("BTCB_VAULT_END_TIME", uint256(1738367999));
    console.log("DepositEndTime: %s", botReceiver);

    vm.startBroadcast(deployerPrivateKey);
    BeraChainVaultAdapter impl = new BeraChainVaultAdapter();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeCall(impl.initialize, (admin, manager, pauser, bot, BTCB, lpToken, botReceiver, depositEndTime))
    );
    vm.stopBroadcast();
    console.log("BeraChainVaultAdapter address: %s", address(proxy));
    console.log("BeraChainVaultAdapter impl: %s", address(impl));
  }
}
