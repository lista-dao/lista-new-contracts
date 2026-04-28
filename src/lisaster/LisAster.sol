// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title LisAster
/// @notice 1:1 LST of ASTER. The MINTER role is granted exclusively to AsterVault, which
///         enforces the invariant `LisAster.totalSupply == sum of AsterVault.deposit`.
contract LisAster is AccessControlEnumerableUpgradeable, ERC20Upgradeable, UUPSUpgradeable {
  /* CONSTANTS */
  bytes32 public constant MINTER = keccak256("MINTER");

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  /// @param minter Sole MINTER (must be the AsterVault proxy address; deployment order
  ///        deploys all proxies first, then initializes).
  function initialize(address admin, address minter, string memory name_, string memory symbol_) external initializer {
    require(admin != address(0), "admin is zero");
    require(minter != address(0), "minter is zero");

    __AccessControlEnumerable_init();
    __ERC20_init(name_, symbol_);
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MINTER, minter);
  }

  /* EXTERNAL */
  function mint(address to, uint256 amount) external onlyRole(MINTER) {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) external onlyRole(MINTER) {
    _burn(from, amount);
  }

  /* UUPS */
  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
