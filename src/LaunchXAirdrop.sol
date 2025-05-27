// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title Lista LaunchX Airdrop
 * @author Lista
 */
contract LaunchXAirdrop is Ownable {
  bytes32 public merkleRoot;
  /// @dev Address of the token to be airdropped
  address public token0;
  /// @dev Address of the token to be returned to users
  address public token1;
  /// @dev Block timestamp when airdrop claim starts
  uint256 public startTime;
  /// @dev Block timestamp when airdrop claim ends
  uint256 public endTime;
  /// @dev Mapping to track claimed airdrops
  mapping(bytes32 => bool) public claimed;

  event Claimed(
    address indexed account,
    address indexed token0,
    address indexed token1,
    uint256 amount0,
    uint256 amount1
  );

  /**
   * @param _token0 Address of the token to be airdropped
   * @param _token1 Address of the token to be returned to users
   * @param _merkleRoot Merkle root of the merkle tree generated for the airdrop by off-chain service
   * @param _startTime Block timestamp when airdrop claim starts
   * @param _endTime Block timestamp when airdrop claim ends
   */
  constructor(
    address _token0,
    address _token1,
    bytes32 _merkleRoot,
    uint256 _startTime,
    uint256 _endTime
  ) Ownable(msg.sender) {
    require(_startTime >= block.timestamp, "Invalid start time");
    require(_endTime > _startTime, "Invalid end time");
    if (_token0 != address(0)) {
      token0 = _token0; // initializing token0 if provided
    }
    require(_token1 != address(0), "Invalid token1 address");
    token1 = _token1;
    merkleRoot = _merkleRoot;
    startTime = _startTime;
    endTime = _endTime;
  }

  /**
   * @dev Update merkle root. Merkle root can only be updated before the airdrop starts.
   */
  function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
    require(block.timestamp < startTime, "Cannot change merkle root after airdrop has started");
    merkleRoot = _merkleRoot;
  }

  /// @dev Initialize token0 address. This can only be done before the airdrop starts.
  function setToken0(address _token0) external onlyOwner {
    require(_token0 != address(0), "Invalid token0 address");
    require(token0 == address(0), "Token0 already set");
    require(block.timestamp < startTime, "Cannot set token0 after airdrop has started");
    token0 = _token0;
  }

  /**
   * @dev Set start Block timestamp of airdrop. Users can only claim airdrop after the new start time.
   */
  function setStartTime(uint256 _startTime) external onlyOwner {
    require(_startTime != startTime, "Start time already set");
    require(endTime > _startTime, "Invalid start time");

    startTime = _startTime;
  }

  /**
   * @dev Set end Block timestamp of airdrop. Users are not allowed to claim airdrop after the new end time.
   */
  function setEndTime(uint256 _endTime) external onlyOwner {
    require(_endTime != endTime, "End time already set");
    require(_endTime > startTime, "Invalid end time");
    endTime = _endTime;
  }

  /**
   * @dev Claim airdrop rewards. Can be called by anyone as long as proof is valid.
   * @param _recipient Address of the token0 and token1 recipient
   * @param _token0 Address of the token0 to be airdropped
   * @param _token1 Address of the token1 to be returned to users
   * @param _amount0 Amount of token0 to be airdropped
   * @param _amount1 Amount of token1 to be returned to users
   * @param _proof Merkle proof of the claim
   */
  function claim(
    address _recipient,
    address _token0,
    address _token1,
    uint256 _amount0,
    uint256 _amount1,
    bytes32[] calldata _proof
  ) external {
    require(block.timestamp >= startTime && block.timestamp <= endTime, "Airdrop not started or has ended");
    require(_recipient != address(0), "Invalid recipient address");
    require(_token0 != address(0) && token0 == _token0, "Invalid token0 address");
    require(_token1 != address(0) && token1 == _token1, "Invalid token1 address");

    bytes32 leaf = keccak256(abi.encode(block.chainid, _recipient, _token0, _token1, _amount0, _amount1));
    require(!claimed[leaf], "Airdrop already claimed");
    require(MerkleProof.verify(_proof, merkleRoot, leaf), "Invalid proof");
    claimed[leaf] = true;

    if (_amount0 > 0) {
      require(IERC20(token0).transfer(_recipient, _amount0), "Token0 transfer failed");
    }

    if (_amount1 > 0) {
      require(IERC20(token1).transfer(_recipient, _amount1), "Token1 transfer failed");
    }

    emit Claimed(_recipient, _token0, _token1, _amount0, _amount1);
  }

  /**
   * @dev Reclaim unclaimed airdrop rewards after the reclaim period expires by contract owner.
   * @param token Address of the token to reclaim (token0 or token1)
   * @param amount Amount of tokens to reclaim
   */
  function reclaim(address token, uint256 amount) external onlyOwner {
    require(token == token0 || token == token1, "Invalid token address");
    require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");
  }
}
