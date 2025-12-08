// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

contract DeployRWAConfig is Script {
  address earnPool1 = 0x4C78D6aFfb5063Af9af922874B0885Bc3f77d114;
  address adapter1 = 0xc12544BE695b6f5aa0A609ab5a2d80B5AD5170b6;

  address earnPool2 = 0x5Ecf6fD97cEB71c3A6C66BcfCaAF66Aeb28edf43;
  address adapter2 = 0x587b55F3c6Ef0693c93404d1c9B8fE81b2cB7205;

  address admin = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address manager = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    vm.startBroadcast(deployerPrivateKey);
    transferRole(earnPool1, deployer, admin, manager);
    transferRole(adapter1, deployer, admin, manager);
    transferRole(earnPool2, deployer, admin, manager);
    transferRole(adapter2, deployer, admin, manager);
    vm.stopPrank();
  }

  function transferRole(address ca, address deployer, address admin, address manager) private {
    IAccessControl(ca).grantRole(DEFAULT_ADMIN_ROLE, admin);
    IAccessControl(ca).grantRole(MANAGER, manager);
    IAccessControl(ca).revokeRole(MANAGER, deployer);
    IAccessControl(ca).revokeRole(DEFAULT_ADMIN_ROLE, deployer);
  }
}
