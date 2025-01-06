// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract NonTransferableLpERC20 is Initializable, OwnableUpgradeable, ERC20Upgradeable, UUPSUpgradeable {
  /**
   * Variables
   */
  mapping(address => bool) public minters;

  /**
   * Events
   */
  event MinterChanged(address minter, bool isAdd);

  /**
   * Modifiers
   */
  modifier onlyMinter() {
    require(minters[msg.sender], "Minter: not allowed");
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Initialize the contract
   * @param _name string
   * @param _symbol string
   */
  function initialize(string memory _name, string memory _symbol) external initializer {
    __Ownable_init(msg.sender);
    __ERC20_init(_name, _symbol);
    __UUPSUpgradeable_init();
  }

  /**
   * @dev burn token from account
   * @param account address
   * @param amount uint256
   */
  function burn(address account, uint256 amount) external onlyMinter {
    _burn(account, amount);
  }

  /**
   * @dev mint token to account
   * @param account address
   * @param amount uint256
   */
  function mint(address account, uint256 amount) external onlyMinter {
    _mint(account, amount);
  }

  /**
   * @dev disable token transfer
   * @param to address
   * @param amount uint256
   */
  function transfer(address to, uint256 amount) public override returns (bool) {
    revert("Not transferable");
  }

  /**
   * @dev disable token transfer
   * @param from address
   * @param to address
   * @param value uint256
   */
  function transferFrom(address from, address to, uint256 value) public override returns (bool) {
    revert("Not transferable");
  }

  /**
   * @dev disable token transfer
   * @param spender address
   * @param amount uint256
   */
  function approve(address spender, uint256 amount) public override returns (bool) {
    revert("Not transferable");
  }

  /**
   * @dev add minter
   * @param minter address
   */
  function addMinter(address minter) external onlyOwner {
    require(minter != address(0), "Minter: zero address");
    require(!minters[minter], "Minter: already a minter");

    minters[minter] = true;
    emit MinterChanged(minter, true);
  }

  /**
   * @dev remove minter
   * @param minter address
   */
  function removeMinter(address minter) external onlyOwner {
    require(minter != address(0), "Minter: zero address");
    require(minters[minter], "Minter: not a minter");

    delete minters[minter];
    emit MinterChanged(minter, false);
  }

  /**
   * UUPSUpgradeable FUNCTIONALITY
   */
  function _authorizeUpgrade(address _newImplementation) internal override onlyOwner {}
}
