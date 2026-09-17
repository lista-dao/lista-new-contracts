// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../../src/surfin/FlexEarnPool.sol";
import "../../src/surfin/LockedEarnPool.sol";
import "../../src/surfin/SurfinAdapter.sol";
import "../../src/surfin/InterestDistributor.sol";

/**
 * @title DeploySurfinImpl
 * @notice Deploys fresh UUPS implementations for the Surfin stack (upgrade prep).
 *         Only SurfinAdapter takes a constructor arg (the immutable asset/USDT), so
 *         the correct USDT is selected per chain. FlexEarnPool / LockedEarnPool /
 *         InterestDistributor have no constructor args.
 *
 *         This script ONLY deploys implementations; the upgrade itself is executed by
 *         the DEFAULT_ADMIN (TimeLock) on each proxy:
 *             proxy.upgradeToAndCall(newImpl, "")
 *         Deploy only the impls you actually intend to upgrade — comment out the rest.
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=<key> BSCSCAN_API_KEY=<key> \
 *     forge script script/surfin/deploy_surfin_impl.s.sol:DeploySurfinImpl \
 *     --rpc-url <bsc|eth|bsc_testnet|sepolia> --broadcast --verify -vvvv
 */
contract DeploySurfinImpl is Script {
  address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955; // 18-dec
  address constant ETH_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6-dec
  // TODO: set the BSC-testnet USDT (the 18-dec MockERC20 from deploy_surfin_testnet) for chainId 97.
  address constant BSC_TESTNET_USDT = address(0);
  // TODO: set the Sepolia USDT (the 6-dec mock from deploy_surfin_sepolia) for chainId 11155111.
  address constant SEPOLIA_USDT = address(0);

  function run() public {
    address usdt = _usdt();

    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    console.log("Chain ID:", block.chainid);
    console.log("USDT (adapter ctor):", usdt);

    vm.startBroadcast(pk);
    address flexImpl = address(new FlexEarnPool());
    address lockedImpl = address(new LockedEarnPool());
    address adapterImpl = address(new SurfinAdapter(usdt));
    address distributorImpl = address(new InterestDistributor());
    vm.stopBroadcast();

    console.log("---- New implementations ----");
    console.log("FlexEarnPool impl:       ", flexImpl);
    console.log("LockedEarnPool impl:     ", lockedImpl);
    console.log("SurfinAdapter impl:      ", adapterImpl);
    console.log("InterestDistributor impl:", distributorImpl);
    console.log('Upgrade via DEFAULT_ADMIN (TimeLock): proxy.upgradeToAndCall(newImpl, "")');
  }

  /// @dev per-chain USDT for the SurfinAdapter constructor.
  function _usdt() internal view returns (address) {
    if (block.chainid == 56) return BSC_USDT;
    if (block.chainid == 1) return ETH_USDT;
    if (block.chainid == 97) {
      require(BSC_TESTNET_USDT != address(0), "set BSC_TESTNET_USDT for the adapter impl");
      return BSC_TESTNET_USDT;
    }
    if (block.chainid == 11155111) {
      require(SEPOLIA_USDT != address(0), "set SEPOLIA_USDT for the adapter impl");
      return SEPOLIA_USDT;
    }
    revert("unsupported chain");
  }
}
