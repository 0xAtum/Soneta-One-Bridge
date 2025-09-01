// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0;

interface IController {
  struct PeerStatus {
    uint64 chainId;
    uint32 lzEndpointId;
    bytes32 peer;
    uint32 requestTimeout;
    uint8 failures;
    bool succeed;
  }

  error PeerAlreadyExists();

  event PeerLinkingCompleted(uint64 _toChainId);

  function IsValidDestination(uint32 _dstEid) external view returns (bool);
}
