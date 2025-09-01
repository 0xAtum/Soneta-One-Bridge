// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBridge {
  error MissingOneTokenAddress();
  error InvalidFunctionUseOtherSimilarName();
  error InvalidDestinationBridge();
  error InvalidReceiver();
  error NotEnoughNativeToPayLayerZeroFee();
  error OnlySafeGuard();

  event OneBridged(uint64 indexed sourceChainid, address indexed to, uint256 amount);

  function isChainLinked(uint64 _chainId) external view returns (bool);

  function sendMessageAsController(uint32 _eid, uint32 _gasLimit, address _refundTo) external payable;

  function estimateFee(uint32 _dstEid, uint256 _amount, uint32 _lzGasLimit) external view returns (uint256);
}
