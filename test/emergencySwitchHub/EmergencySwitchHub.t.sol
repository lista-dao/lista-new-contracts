// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
// import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "../../src/emergencySwtichHub/EmergencySwitchHub.sol";

contract EmergencySwitchHubTest is Test {
  address admin = address(0x1A11AA);
  address manager = makeAddr("MANAGER");
  address pauser = makeAddr("PAUSER");

  address timelock = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
  address moolah = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

  EmergencySwitchHub emergencySwitchHub;

  function setUp() public {
    vm.createSelectFork("https://bsc-dataseed.binance.org");

    EmergencySwitchHub emergencySwitchHubImpl = new EmergencySwitchHub();
    ERC1967Proxy proxy_ = new ERC1967Proxy(
      address(emergencySwitchHubImpl),
      abi.encodeWithSelector(EmergencySwitchHub.initialize.selector, admin, manager, pauser)
    );
    emergencySwitchHub = EmergencySwitchHub(address(proxy_));

    // grant hub as PAUSER and MANAGER
    vm.prank(timelock);
    IAccessControl(moolah).grantRole(keccak256("PAUSER"), address(emergencySwitchHub));
    vm.prank(timelock);
    IAccessControl(moolah).grantRole(keccak256("MANAGER"), address(emergencySwitchHub));

    address[] memory pausableContracts = new address[](1);
    pausableContracts[0] = moolah;

    // add moolah as pausable contract
    vm.prank(manager);
    emergencySwitchHub.addPausableContracts(pausableContracts);
  }

  function test_PauseAll() public {
    // pause all contracts
    vm.prank(pauser);
    emergencySwitchHub.pauseAll();

    assertTrue(IPausable(moolah).paused());
  }

  function test_UnpauseAll() public {
    // pause all contracts
    vm.prank(pauser);
    emergencySwitchHub.pauseAll();

    assertTrue(IPausable(moolah).paused());

    // unpause all contracts
    vm.prank(manager);
    emergencySwitchHub.unpauseAll();

    assertFalse(IPausable(moolah).paused());
  }

  function test_PauseContracts() public {
    // pause specific contracts
    address[] memory contractsToPause = new address[](1);
    contractsToPause[0] = moolah;

    vm.prank(pauser);
    emergencySwitchHub.pauseContracts(contractsToPause);

    assertTrue(IPausable(moolah).paused());
  }

  function test_grantNewPauserRole() public {
    address newPauser = makeAddr("NEW_PAUSER");

    // grant NEW_PAUSER as PAUSER by MANAGER
    vm.prank(manager);
    IAccessControl(address(emergencySwitchHub)).grantRole(keccak256("PAUSER"), newPauser);

    // pause all contracts by NEW_PAUSER
    vm.prank(newPauser);
    emergencySwitchHub.pauseAll();

    assertTrue(IPausable(moolah).paused());
  }
}
