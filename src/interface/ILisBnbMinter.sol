// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILisBnbMinter {
  struct UserRequest {
    uint256 id;
    uint256 batchId;
    uint256 bnbAmount;
    uint256 lisBnbAmount;
    uint256 time;
  }

  struct MPCWallet {
    address walletAddress;
    uint256 balance;
    uint256 cap;
  }

  struct RewardCompound {
    uint256 remainingLisBnb;
    uint256 dailyLisBnbAmt;
    uint256 lastCompoundedTime;
  }

  ///// ------------------------------ Events ------------------------------ /////
  event Deposited(address indexed user, uint256 bnbAmount, uint256 lisBnbAmount);
  event WithdrawalRequested(address indexed user, uint256 bnbAmount, uint256 lisBnbAmount);
  event WithdrawalClaimed(address indexed user, uint256 bnbAmount);
  event ReserveDeposited(address indexed user, uint256 bnbAmount, uint256 lisBnbAmount);
  event ReserveWithdrawalRequested(address indexed user, uint256 bnbAmount, uint256 lisBnbAmount);
  event ReserveWithdrawalClaimed(address indexed user, uint256 bnbAmount);
  event BatchWithdrawalRequested(uint256 batchId, uint256 bnbAmount, uint256 lisBnbAmount);
  event BatchWithdrawalClaimed(uint256 batchId, uint256 bnbAmount);
  event RewardsDeposited(address indexed user, uint256 bnbAmount, uint256 lisBnbAmount);
  event RewardsCompounded(uint256 lisBnbAmount);
  event FeeRateChanged(uint256 oldFeeRate, uint256 newFeeRate);
  event RedirectAddressChanged(address oldAddress, address newAddress);
  event RevenuePoolChanged(address oldAddress, address newAddress);
  event MpcWalletCapChanged(address wallet, uint256 oldCap, uint256 newCap);
  event MpcWalletRemoved(address wallet);
  event MpcWalletAdded(address wallet, uint256 cap);
}
