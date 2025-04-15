// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "../interface/ILisBNB.sol";

contract LisBNB is ILisBNB, ERC20Upgradeable, AccessControlUpgradeable {
  string private constant _name = "Lista BNB";
  string private constant _symbol = "LisBNB";
  address public minter;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * ------ Modifiers ------
   */
  modifier onlyMinter() {
    require(minter == msg.sender, "Minter: not allowed");
    _;
  }

  /**
   * ------ Events ------
   */
  event MinterChanged(address oldMinter, address newMinter);

  /**
   * @dev Initialize the contract
   * @param _admin address
   */
  function initialize(address _admin) external initializer {
    require(_admin != address(0), "zero address provided");
    __AccessControl_init();
    __ERC20_init(_name, _symbol);
    grantRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  /**
   * @dev Get the name of the token
   * @return string memory
   */
  function name() public pure override returns (string memory) {
    return _name;
  }

  /**
   * @dev Get the symbol of the token
   * @return string memory
   */
  function symbol() public pure override returns (string memory) {
    return _symbol;
  }

  /**
   * @dev Mint tokens to the specified account
   * @param _account address
   * @param _amount uint256
   */
  function mint(address _account, uint256 _amount) external onlyMinter {
    _mint(_account, _amount);
  }

  /**
   * @dev Burn tokens from the specified account
   * @param _account address
   * @param _amount uint256
   */
  function burn(address _account, uint256 _amount) external onlyMinter {
    _burn(_account, _amount);
  }

  /**
   * @dev Set new minter address
   * @param _minter minter address
   */
  function setMinter(address _minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(minter != address(0), "Minter: zero address");
    require(_minter != minter, "Minter: already a minter");
    address oldMinter = minter;
    minter = _minter;
    emit MinterChanged(oldMinter, minter);
  }
}
