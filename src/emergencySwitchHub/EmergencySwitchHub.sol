// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interface/IPausable.sol";

/**
 * @title Emergency Switch Hub
 * @author Lista
 * @dev pause all/specific core contracts in case of emergency
 */
contract EmergencySwitchHub is AccessControlEnumerableUpgradeable, UUPSUpgradeable {
  using EnumerableSet for EnumerableSet.AddressSet;

  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant PAUSER = keccak256("PAUSER");

  /// @dev lista dao core contracts
  EnumerableSet.AddressSet private pausableContracts;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Initialize the contract
   * @param _admin address
   * @param _manager address
   * @param _pauser address
   */
  function initialize(address _admin, address _manager, address _pauser) public initializer {
    require(_admin != address(0), "admin is the zero address");
    require(_manager != address(0), "manager is the zero address");
    require(_pauser != address(0), "pauser is the zero address");

    __AccessControl_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(MANAGER, _manager);
    _grantRole(PAUSER, _pauser);

    // set PAUSER's role admin to MANAGER
    // MANAGER can add/remove PAUSERs
    _setRoleAdmin(PAUSER, MANAGER);
  }

  /**
   * @dev Pause all contracts
   */
  function pauseAll() external onlyRole(PAUSER) {
    _togglePausables(true);
  }

  /**
   * @dev Unpause all contracts
   */
  function unpauseAll() external onlyRole(MANAGER) {
    _togglePausables(false);
  }

  /**
   * @dev Pause specific contracts
   * @param contracts addresses of contracts to be paused
   */
  function pauseContracts(address[] calldata contracts) external onlyRole(PAUSER) {
    // check contains in pauableContracts
    for (uint i = 0; i < contracts.length; i++) {
      address pausable = contracts[i];
      if (pausableContracts.contains(pausable)) {
        if (!IPausable(pausable).paused()) {
          IPausable(pausable).pause();
        }
      }
    }
  }

  /**
   * @dev Unpause specific contracts
   * @param contracts addresses of contracts to be unpaused
   */
  function unpauseContracts(address[] calldata contracts) external onlyRole(MANAGER) {
    // check contains in pauableContracts
    for (uint i = 0; i < contracts.length; i++) {
      address pausable = contracts[i];
      if (pausableContracts.contains(pausable)) {
        if (IPausable(pausable).paused()) {
          IPausable(pausable).unpause();
        }
      }
    }
  }

  /**
   * @dev Get all pausable contracts
   */
  function getPausableContracts() external view returns (address[] memory) {
    address[] memory contracts = new address[](pausableContracts.length());
    for (uint i = 0; i < pausableContracts.length(); i++) {
      contracts[i] = pausableContracts.at(i);
    }
    return contracts;
  }

  /* =================================== */
  /*            ADMIN FUNCTIONS          */
  /* =================================== */

  /**
   * @dev Add a pausable contract to the hub
   */
  function addPausableContracts(address[] memory pausable) external onlyRole(MANAGER) {
    require(pausable.length > 0, "hub/empty-addresses-provided");
    for (uint i = 0; i < pausable.length; i++) {
      address pausableAddress = pausable[i];
      require(pausableAddress != address(0), "hub/zero-address-provided");
      pausableContracts.add(pausableAddress);
    }
  }

  /**
   * @dev Remove a pausable contract from the hub
   */
  function removePausableContracts(address[] memory pausable) external onlyRole(MANAGER) {
    require(pausable.length > 0, "hub/empty-addresses-provided");
    for (uint i = 0; i < pausable.length; i++) {
      address pausableAddress = pausable[i];
      require(pausableAddress != address(0), "hub/zero-address-provided");
      pausableContracts.remove(pausableAddress);
    }
  }

  /* =================================== */
  /*          INTERNAL FUNCTIONS         */
  /* =================================== */
  function _togglePausables(bool pause) internal {
    for (uint i = 0; i < pausableContracts.length(); i++) {
      address pausable = pausableContracts.at(i);
      if (pause) {
        if (!IPausable(pausable).paused()) {
          IPausable(pausable).pause();
        }
      } else {
        if (IPausable(pausable).paused()) {
          IPausable(pausable).unpause();
        }
      }
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
