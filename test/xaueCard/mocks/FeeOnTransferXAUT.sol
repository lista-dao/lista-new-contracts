// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev XAUt look-alike with Tether's fee switch turned on: every transfer loses `feeBps` to `feeSink`.
contract FeeOnTransferXAUT is ERC20 {
  uint256 public feeBps;
  address public feeSink;

  constructor(uint256 _feeBps, address _feeSink) ERC20("Mock XAUT (fee)", "XAUT") {
    feeBps = _feeBps;
    feeSink = _feeSink;
  }

  function decimals() public pure override returns (uint8) {
    return 6;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function _update(address from, address to, uint256 value) internal override {
    if (from != address(0) && to != address(0) && feeBps > 0) {
      uint256 fee = (value * feeBps) / 10_000;
      super._update(from, feeSink, fee);
      value -= fee;
    }
    super._update(from, to, value);
  }
}
