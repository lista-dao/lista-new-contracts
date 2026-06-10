// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title SlisXAUE
 * @notice Pure ERC20 share token for Lista's XAU-staking product. No business logic, no Pausable.
 *         Only MINTER (granted to XAUTStaking) can mint/burn. Free transfer preserves DeFi composability.
 */
contract SlisXAUE is ERC20Upgradeable, AccessControlEnumerableUpgradeable, UUPSUpgradeable {
  /// @notice The only role allowed to mint and burn. Granted to XAUTStaking after deployment.
  bytes32 public constant MINTER = keccak256("MINTER");

  /* CONSTRUCTOR */
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* INITIALIZER */
  /// @param admin DEFAULT_ADMIN_ROLE: upgrades + grant/revoke MINTER
  /// @param name_ ERC20 name (e.g. "Staked Lista XAUE")
  /// @param symbol_ ERC20 symbol (e.g. "slisXAUE")
  /// @dev MINTER (XAUTStaking) is NOT granted here — the admin grants it post-deploy via
  ///      grantRole(MINTER, staking). Kept out of initialize to avoid the slisXAUE <-> XAUTStaking
  ///      circular construction dependency (mirrors XAUEAdapter.setStaking); each proxy's init stays
  ///      atomic and front-run-safe.
  function initialize(address admin, string memory name_, string memory symbol_) external initializer {
    require(admin != address(0), "admin is zero");
    require(bytes(name_).length > 0, "name is empty");
    require(bytes(symbol_).length > 0, "symbol is empty");

    __ERC20_init(name_, symbol_);
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
  }

  /// @notice 18 decimals fixed.
  function decimals() public pure override returns (uint8) {
    return 18;
  }

  /* EXTERNAL */

  /// @notice Mint shares to `to`. Only callable by MINTER (XAUTStaking).
  function mint(address to, uint256 amount) external onlyRole(MINTER) {
    _mint(to, amount);
  }

  /// @notice Burn shares from `from`. Only callable by MINTER.
  /// @dev XAUTStaking burns user shares at requestWithdraw. MINTER is trusted (deployed contract).
  function burn(address from, uint256 amount) external onlyRole(MINTER) {
    _burn(from, amount);
  }

  /* INTERNAL */
  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
