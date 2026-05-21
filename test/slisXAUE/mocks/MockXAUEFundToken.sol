// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./MockXAUEOracle.sol";

/**
 * @notice Test-only XAUE FundToken mock. Implements the subset used by XAUEAdapter:
 *   - sync mint(assetAmount) returns sharesAmount (pulls XAUT → simulated vault, mints XAUE)
 *   - async requestRedemption(shareAmount) returns reqId (burns shares; assetAmount locked at NAV)
 *   - approveRedemption(reqId, ...) transfers XAUT back to the requester
 *   - whitelist + minDepositAmount + minRedeemShares + paused
 */
contract MockXAUEFundToken is ERC20 {
  using SafeERC20 for IERC20;

  IERC20 public immutable xaut;
  MockXAUEOracle public immutable oracle;

  uint256 public minDepositAmount = 1000; // 0.001 XAUT
  uint256 public minRedeemShares = 1e18; // 1 XAUE
  bool public paused;
  mapping(address => bool) public whitelist;

  enum Status {
    Pending,
    Executed,
    Rejected
  }

  struct Request {
    address user;
    uint256 shareAmount;
    uint256 assetAmount;
    Status status;
  }

  Request[] public redemptions;

  uint256 private constant SCALE = 1e30; // share-wei × NAV / 1e30 = xaut-wei

  constructor(address _xaut, address _oracle) ERC20("Mock XAUE", "XAUE") {
    xaut = IERC20(_xaut);
    oracle = MockXAUEOracle(_oracle);
  }

  function addToWhitelist(address account) external {
    whitelist[account] = true;
  }

  function setPaused(bool _paused) external {
    paused = _paused;
  }

  function setMinDepositAmount(uint256 _v) external {
    minDepositAmount = _v;
  }

  function setMinRedeemShares(uint256 _v) external {
    minRedeemShares = _v;
  }

  function mint(uint256 assetAmount) external returns (uint256 shareAmount) {
    require(!paused, "paused");
    require(whitelist[msg.sender], "not whitelisted");
    require(assetAmount >= minDepositAmount, "below min deposit");
    uint256 nav = oracle.getLatestPrice();
    require(nav > 0, "zero nav");
    // shareAmount = assetAmount × 1e30 / nav (asset 6-dec × 1e30 / nav 1e18 = share 18-dec)
    shareAmount = (assetAmount * SCALE) / nav;
    require(shareAmount > 0, "zero shares");
    xaut.safeTransferFrom(msg.sender, address(this), assetAmount);
    _mint(msg.sender, shareAmount);
  }

  function requestRedemption(uint256 shareAmount) external returns (uint256 reqId) {
    require(!paused, "paused");
    require(whitelist[msg.sender], "not whitelisted");
    require(shareAmount >= minRedeemShares, "below min redeem");
    uint256 nav = oracle.getLatestPrice();
    require(nav > 0, "zero nav");
    uint256 assetAmount = (shareAmount * nav) / SCALE;
    require(assetAmount > 0, "zero asset");
    _burn(msg.sender, shareAmount);
    reqId = redemptions.length;
    redemptions.push(
      Request({ user: msg.sender, shareAmount: shareAmount, assetAmount: assetAmount, status: Status.Pending })
    );
  }

  /// @notice Approve a pending redemption — transfers XAUT back to the original requester.
  function approveRedemption(uint256 reqId, address user, uint256 assetAmount, uint256 shareAmount) external {
    Request storage req = redemptions[reqId];
    require(req.status == Status.Pending, "not pending");
    require(req.user == user && req.assetAmount == assetAmount && req.shareAmount == shareAmount, "mismatch");
    req.status = Status.Executed;
    xaut.safeTransfer(user, assetAmount);
  }
}
