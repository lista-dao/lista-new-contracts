// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import "../../src/slisXAUE/XAUTStaking.sol";
import "../../src/slisXAUE/XAUEAdapter.sol";

/**
 * @title UpgradeSlisXAUE
 * @notice Deploys fresh XAUTStaking + XAUEAdapter implementations and points the existing Sepolia
 *         UUPS proxies at them. Storage layout is unchanged between the previous deploy and this
 *         revision (only logic + events differ), so no init-on-upgrade call is needed.
 *
 *         SlisXAUE is NOT touched (no contract changes in this round).
 */
contract UpgradeSlisXAUE is Script {
  // Sepolia proxies (re-deployed 2026-06-05). The previous set (staking 0x1d69…0362Ce,
  // adapter 0x54B6…3D1b0f) was abandoned: those proxies were initialize()d with Phase-1 code, and a
  // later upgrade inserted `slisXAUE` mid-struct on the adapter, shifting storage by one slot with no
  // reinitializer (adapter.slisXAUE -> deployer EOA, feeReceiver/feeRate/maxDeltaBps wrong). Fixed by a
  // fresh atomic-init deploy (deploy_slisXAUE.s.sol). Re-whitelist the new adapter on the XAUE FundToken.
  address public constant STAKING_PROXY = 0x834DFCf86f2c232A385CD97397C9D231B5db3172;
  address public constant ADAPTER_PROXY = 0x473276Da63CBf753E24084fAb5852d8A6Fb97f2e;

  // XAUEAdapter immutable constructor arg
  address public constant XAUT = 0x1467CF3bda74b1811B93cf66CdE24F81a241FCe2;

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer:", deployer);

    vm.startBroadcast(deployerPrivateKey);

    // 1) New XAUTStaking impl + upgrade
    XAUTStaking newStakingImpl = new XAUTStaking();
    UUPSUpgradeable(STAKING_PROXY).upgradeToAndCall(address(newStakingImpl), "");
    console.log("XAUTStaking new impl:", address(newStakingImpl));

    // 2) New XAUEAdapter impl + upgrade
    XAUEAdapter newAdapterImpl = new XAUEAdapter(XAUT);
    UUPSUpgradeable(ADAPTER_PROXY).upgradeToAndCall(address(newAdapterImpl), "");
    console.log("XAUEAdapter new impl:", address(newAdapterImpl));

    vm.stopBroadcast();

    console.log("=============================================");
    console.log("Upgrade complete on Sepolia");
    console.log("=============================================");
    console.log("XAUTStaking proxy: ", STAKING_PROXY);
    console.log("XAUEAdapter proxy: ", ADAPTER_PROXY);
    console.log("=============================================");
  }
}
