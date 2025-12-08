// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../rwa/interface/IAsyncVault.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./MockERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAsyncVault is IAsyncVault {
  using Math for uint256;
  uint256 public convertRate;

  mapping(address => uint256) public pendingDeposits;
  mapping(address => uint256) public pendingRedeems;

  address public asset;
  MockERC20 public shareToken;

  uint256 public constant PRECISION = 1e18;

  constructor(address _asset, address _shareToken, uint256 _convertRate) {
    require(_asset != address(0), "MockAsyncVault: asset is the zero address");
    require(_shareToken != address(0), "MockAsyncVault: shareToken is the zero address");
    require(_convertRate > 0, "MockAsyncVault: convertRate is zero");
    asset = _asset;
    shareToken = MockERC20(_shareToken);
    convertRate = _convertRate;
  }

  function totalAssets() public view returns (uint256) {
    return convertToAssets(shareToken.totalSupply());
  }
  function convertToShares(uint256 assets) public view returns (uint256) {
    return assets.mulDiv(PRECISION, convertRate);
  }
  function convertToAssets(uint256 shares) public view returns (uint256) {
    return shares.mulDiv(convertRate, PRECISION);
  }
  function balanceOf(address account) external view returns (uint256) {
    return shareToken.balanceOf(account);
  }
  function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256) {
    IERC20(asset).transferFrom(msg.sender, address(this), assets);
    uint256 share = convertToShares(assets);
    pendingDeposits[owner] += share;
    return share;
  }
  function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256) {
    require(shares <= shareToken.balanceOf(owner), "MockAsyncVault: insufficient shares");
    shareToken.burn(owner, shares);
    pendingRedeems[owner] += shares;
    return shares;
  }
  function maxMint(address account) external view returns (uint256) {
    return pendingDeposits[account];
  }
  function maxRedeem(address account) external view returns (uint256) {
    return pendingRedeems[account];
  }
  function mint(uint256 shares, address receiver) external returns (uint256) {
    require(shares <= pendingDeposits[receiver], "MockAsyncVault: insufficient pending deposits");
    pendingDeposits[receiver] -= shares;

    shareToken.mint(receiver, shares);
    return convertToAssets(shares);
  }
  function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
    require(shares <= pendingRedeems[owner], "MockAsyncVault: insufficient pending redeems");
    pendingRedeems[owner] -= shares;

    uint256 assets = convertToAssets(shares);
    IERC20(asset).transfer(receiver, assets);
    return assets;
  }

  function setConvertRate(uint256 _convertRate) external {
    convertRate = _convertRate;
  }
}
