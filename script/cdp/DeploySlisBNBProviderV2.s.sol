// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { SlisBNBProviderV2 } from "../../src/cdp/contracts/ceros/provider/SlisBNBProviderV2.sol";

/**
 * Deploys the SlisBNBProviderV2 implementation and prints the calldata for the cut-over
 * (see docs/slisbnb-provider-v2-migration.md).
 *
 * forge script script/cdp/DeploySlisBNBProviderV2.s.sol:DeploySlisBNBProviderV2 \
 *   --rpc-url https://bsc-dataseed.binance.org --etherscan-api-key <key> --broadcast --verify -vvv
 *
 * Env: DEPLOYER_PRIVATE_KEY, TIMELOCK_SALT (bytes32, next Changelog salt)
 */
contract DeploySlisBNBProviderV2 is Script {
  address constant PROVIDER = 0xfD31e1C5e5571f8E7FE318f80888C1e6da97819b; // CDP SlisBNBProvider proxy
  address constant MINTER = 0x2959c423bfe5Cc6E41516599D982A29C0773F11a; // SlisBNBxMinter
  address constant STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6; // ListaStakeManager
  address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address constant ASTER = 0xE861dd4b0AB6f3a42943e6EF441c3C611CD1bec2; // Aster YieldProxy
  address constant PENDLE = 0x27FaF900007B4cBa7803000251ec96Bc69ff1BEa; // PendleClisBNBSY
  address constant SIGMA = 0x8B98563d66B74e5a644BFf78fC72c86bbA847a29; // SigmaClisBNBSY
  uint256 constant DELAY = 86400;

  function run() public {
    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    bytes32 salt = vm.envBytes32("TIMELOCK_SALT");

    vm.startBroadcast(pk);
    SlisBNBProviderV2 impl = new SlisBNBProviderV2(MINTER, STAKE_MANAGER);
    vm.stopBroadcast();
    console.log("SlisBNBProviderV2 impl:", address(impl));

    address[] memory accounts = new address[](3);
    (accounts[0], accounts[1], accounts[2]) = (ASTER, PENDLE, SIGMA);
    address[] memory whitelist = new address[](2); // current CDP whitelist: Aster and Pendle; Sigma is not
    (whitelist[0], whitelist[1]) = (ASTER, PENDLE);

    // step 1 (Manager Safe -> SlisBNBxMinter): addModule(provider, {discount 0, feeRate 3%, provider})
    bytes memory addModule = abi.encodeWithSignature(
      "addModule(address,(uint24,uint24,address))",
      PROVIDER,
      uint24(0),
      uint24(30000),
      PROVIDER
    );
    console.log("step 1 to SlisBNBxMinter, data:");
    console.logBytes(addModule);

    // steps 2-3 (Proposer Safe -> TimeLock): schedule / execute provider.upgradeToAndCall(impl, migrateFromCdp(...))
    bytes memory upgrade = abi.encodeWithSignature(
      "upgradeToAndCall(address,bytes)",
      address(impl),
      abi.encodeCall(SlisBNBProviderV2.migrateFromCdp, (accounts, whitelist))
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
    console.log("step 2 to TimeLock", TIMELOCK, "schedule data:");
    console.logBytes(schedule);
    console.log("step 3 to TimeLock (after delay), execute data:");
    console.logBytes(execute);
  }
}
