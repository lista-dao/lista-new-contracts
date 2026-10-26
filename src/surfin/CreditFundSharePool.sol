// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { CreditFundBase } from "./CreditFundBase.sol";

/**
 * @title CreditFundSharePool
 * @notice Shared base for pools whose position is a standard ERC20 share: the flex pool
 *         (1:1 LP) and the NAV pool (shares priced at a published NAV).
 *
 *  - transfer / approve / transferFrom are neither pause- nor whitelist-gated: pause
 *    stops pool flows, not the token, and the whitelist only decides who may deposit;
 *  - `cap` bounds the pool's size in asset units (what counts is `_capUsage()`, defined
 *    by the product); it is 0 (closed) until MANAGER sets it;
 *  - shares can never be parked on the pool or the adapter; the pool only ever holds
 *    shares it escrowed itself.
 */
abstract contract CreditFundSharePool is CreditFundBase, ERC20Upgradeable {
  using EnumerableSet for EnumerableSet.AddressSet;

  /* VARIABLES */
  // ceiling on `_capUsage() + deposit`, asset units; 0 keeps deposits closed
  uint256 public cap;
  // when enabled, both the depositor and the share receiver must be whitelisted
  bool public whitelistEnabled;
  EnumerableSet.AddressSet private whitelist;
  // set only while the pool moves shares into its own escrow
  bool private _escrowing;

  /* EVENTS */
  event SetCap(uint256 cap);
  event SetWhitelistEnabled(bool enabled);
  event WhitelistChanged(address indexed user, bool ok);

  /* INITIALIZER */
  function __CreditFundSharePool_init(
    address _admin,
    address _manager,
    address _pauser,
    address _bot,
    address _asset,
    address _adapter,
    string memory _name,
    string memory _symbol
  ) internal onlyInitializing {
    __CreditFundBase_init(_admin, _manager, _pauser, _bot, _asset, _adapter, _name, _symbol);
    __ERC20_init(_name, _symbol);
  }

  /* ABSTRACT */
  /// @dev the pool's current size in asset units, measured against `cap`
  function _capUsage() internal view virtual returns (uint256);

  /* MANAGER FUNCTIONS */
  /// @dev lowering the cap below the current usage simply closes deposits
  function setCap(uint256 _cap) external onlyRole(MANAGER) {
    require(_cap != cap, "same cap");
    cap = _cap;
    emit SetCap(_cap);
  }

  function setWhitelistEnabled(bool enabled) external onlyRole(MANAGER) {
    require(enabled != whitelistEnabled, "same status");
    whitelistEnabled = enabled;
    emit SetWhitelistEnabled(enabled);
  }

  /// @dev removal only affects new deposits; existing shares keep every exit path
  function setWhitelist(address[] calldata users, bool ok) external onlyRole(MANAGER) {
    for (uint256 i = 0; i < users.length; i++) {
      require(users[i] != address(0), "user is zero address");
      require(ok ? whitelist.add(users[i]) : whitelist.remove(users[i]), "same status");
      emit WhitelistChanged(users[i], ok);
    }
  }

  /* VIEWS */
  function isWhitelisted(address user) external view returns (bool) {
    return whitelist.contains(user);
  }

  function getWhitelist() external view returns (address[] memory) {
    return whitelist.values();
  }

  function name() public view override(CreditFundBase, ERC20Upgradeable) returns (string memory) {
    return CreditFundBase.name();
  }

  function symbol() public view override(CreditFundBase, ERC20Upgradeable) returns (string memory) {
    return CreditFundBase.symbol();
  }

  function decimals() public view override(CreditFundBase, ERC20Upgradeable) returns (uint8) {
    return CreditFundBase.decimals();
  }

  /* INTERNAL FUNCTIONS */
  /// @dev the gates every deposit passes: receiver, minimum, cap, whitelist and the adapter slot
  function _checkDeposit(address receiver, uint256 amount) internal view {
    require(amount > 0, "amount is zero");
    require(receiver != address(0), "receiver is zero address");
    require(amount >= minDeposit, "deposit below minimum");
    require(_capUsage() + amount <= cap, "exceeds cap");
    if (whitelistEnabled) {
      require(whitelist.contains(msg.sender) && whitelist.contains(receiver), "not whitelisted");
    }
    _checkAdapterSlot();
  }

  /// @dev `type(uint256).max` stands for the caller's whole balance at execution, so a
  ///      full exit cannot be front-run into a sub-minimum leftover by a dust transfer
  function _resolveAll(uint256 shares) internal view returns (uint256) {
    return shares == type(uint256).max ? balanceOf(msg.sender) : shares;
  }

  /// @dev move `shares` of `from` into the pool's own escrow
  function _escrow(address from, uint256 shares) internal {
    _escrowing = true;
    _transfer(from, address(this), shares);
    _escrowing = false;
  }

  /// @dev shares held by the pool or the adapter would be principal that nobody can exit
  function _update(address from, address to, uint256 value) internal virtual override {
    require((to != address(this) || _escrowing) && to != adapter, "invalid receiver");
    super._update(from, to, value);
  }

  uint256[46] private __gap;
}
