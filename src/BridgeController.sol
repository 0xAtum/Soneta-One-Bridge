// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Import necessary interfaces and contracts
import { AddressCast } from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import {
  MessagingFee,
  MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OAppOptionsType3 } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import { ReadCodecV1, EVMCallRequestV1 } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/ReadCodecV1.sol";
import { OAppRead } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppRead.sol";
import { OAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppCore.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IBridge } from "./interfaces/IBridge.sol";
import { IController } from "./interfaces/IController.sol";

import { IMessageLibManager } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/**
 * @title BridgeController
 * @notice Manages the bridge to enable a immutable peering on LayerZero, while allowing for potential expansion of the
 * bridge to other chains.
 */
contract BridgeController is IController, OAppRead, OAppOptionsType3 {
  uint32 public constant DEFAULT_GAS_LIMIT = 200_000;
  uint32 private constant READ_TIME_DELAY = 6 minutes;
  uint32 private constant TIMEOUT_OFFSET = 10 minutes;
  uint8 public constant MAX_RETRY_PEER = 3;

  uint16 public constant READ_TYPE = 1;

  address public immutable BRIDGE_ADDRESS;

  /// @notice LayerZero read channel ID.
  uint32 public READ_CHANNEL;

  mapping(uint64 chainId => PeerStatus) internal peerStatusList;
  mapping(uint32 lzEID => uint64 chainId) public layerZeroToChainId;
  mapping(bytes32 guid => uint32 chainId) public messageToTargetChainId;

  constructor(address _endpoint, address _owner, address _bridgeAddress, uint32 _readChannel)
    OAppRead(_endpoint, _owner)
    Ownable(_owner)
  {
    READ_CHANNEL = _readChannel;
    BRIDGE_ADDRESS = _bridgeAddress;

    _setPeer(_readChannel, AddressCast.toBytes32(address(this)));
  }

  function setBridgePeer(
    uint64 _targetChainId,
    uint32 _eid,
    bytes32 _peer,
    address _libReceiver,
    address _libSender,
    SetConfigParam[] calldata _configRead,
    SetConfigParam[] calldata _configWrite
  ) external onlyOwner {
    PeerStatus storage status = peerStatusList[_targetChainId];

    if (status.requestTimeout != 0) {
      require(!status.succeed, PeerAlreadyExists());
      require(status.requestTimeout <= block.timestamp, PeerAlreadyExists());
      require(status.failures >= MAX_RETRY_PEER, PeerAlreadyExists());
    }

    peerStatusList[_targetChainId] = PeerStatus(_targetChainId, _eid, _peer, 1, 0, false);

    status = peerStatusList[_targetChainId];
    layerZeroToChainId[_eid] = _targetChainId;

    OAppCore(BRIDGE_ADDRESS).setPeer(_eid, _peer);

    IMessageLibManager(endpoint).setConfig(BRIDGE_ADDRESS, _libReceiver, _configRead);
    IMessageLibManager(endpoint).setConfig(BRIDGE_ADDRESS, _libSender, _configRead);
    IMessageLibManager(endpoint).setConfig(BRIDGE_ADDRESS, _libSender, _configWrite);
  }

  function validatePeer(uint32 _targetChainId, uint32 _gasLimit, bytes calldata _extraOptions)
    external
    payable
    onlyOwner
  {
    PeerStatus storage status = peerStatusList[_targetChainId];

    require(status.requestTimeout == 1, "Validation already sent");

    (uint256 callingFee, uint256 readingFee) = getLzFees(_targetChainId, _gasLimit, _extraOptions);
    require(msg.value == callingFee + readingFee, "Not enough native fee");

    IBridge(BRIDGE_ADDRESS).sendMessageAsController{ value: callingFee }(status.lzEndpointId, _gasLimit, msg.sender);
    MessagingReceipt memory receipt = this.readBridgeConnection{ value: readingFee }(
      _peerToAddress(status.peer), status.lzEndpointId, READ_TIME_DELAY, _extraOptions
    );

    messageToTargetChainId[receipt.guid] = _targetChainId;

    status.requestTimeout = uint32(block.timestamp + READ_TIME_DELAY + TIMEOUT_OFFSET);
  }

  function retryBridgePeering(uint32 _targetChainId, uint32 _gasLimit, bytes calldata _extraOptions) external payable {
    PeerStatus storage status = peerStatusList[_targetChainId];

    require(status.lzEndpointId != 0, "Peer not set");
    require(!status.succeed, "Peer already succeed");
    require(status.requestTimeout < block.timestamp, "Request still ongoing");
    require(status.failures < MAX_RETRY_PEER, "Max retry reached");

    status.failures++;
    status.requestTimeout = uint32(block.timestamp + TIMEOUT_OFFSET);

    (, uint256 readingFee) = getLzFees(_targetChainId, _gasLimit, _extraOptions);
    require(msg.value == readingFee, "Not enough native fee");

    MessagingReceipt memory receipt =
      this.readBridgeConnection{ value: readingFee }(_peerToAddress(status.peer), status.lzEndpointId, 0, _extraOptions);

    messageToTargetChainId[receipt.guid] = _targetChainId;
  }

  function getLzFees(uint64 _chainId, uint32 _gasLimit, bytes calldata _extraOptions)
    public
    view
    returns (uint256 calling_, uint256 reading_)
  {
    PeerStatus memory status = peerStatusList[_chainId];

    calling_ =
      IBridge(BRIDGE_ADDRESS).estimateFee(status.lzEndpointId, 0, _gasLimit == 0 ? DEFAULT_GAS_LIMIT : _gasLimit);
    reading_ = quoteReadFee(_peerToAddress(status.peer), status.lzEndpointId, _extraOptions).nativeFee;

    return (calling_, reading_);
  }

  function _peerToAddress(bytes32 _peer) private pure returns (address) {
    return address(uint160(uint256(_peer)));
  }

  function quoteReadFee(address _targetContractAddress, uint32 _targetEid, bytes calldata _extraOptions)
    public
    view
    returns (MessagingFee memory fee)
  {
    return _quote(
      READ_CHANNEL,
      _getCmd(_targetContractAddress, _targetEid, 0),
      combineOptions(READ_CHANNEL, READ_TYPE, _extraOptions),
      false
    );
  }

  function readBridgeConnection(
    address _targetContractAddress,
    uint32 _targetEid,
    uint64 _readDelay,
    bytes calldata _extraOptions
  ) external payable returns (MessagingReceipt memory) {
    require(msg.sender == address(this), "Only callable by BridgeController");

    bytes memory cmd = _getCmd(_targetContractAddress, _targetEid, _readDelay);

    return _lzSend(
      READ_CHANNEL,
      cmd,
      combineOptions(READ_CHANNEL, READ_TYPE, _extraOptions),
      MessagingFee(msg.value, 0),
      payable(msg.sender)
    );
  }

  function _getCmd(address _targetContractAddress, uint32 _targetEid, uint64 _readDelay)
    internal
    view
    returns (bytes memory)
  {
    bytes memory callData = abi.encodeWithSelector(IBridge.isChainLinked.selector, uint64(block.chainid));

    EVMCallRequestV1[] memory readRequests = new EVMCallRequestV1[](1);
    readRequests[0] = EVMCallRequestV1({
      appRequestLabel: 1, // Label for tracking this specific request
      targetEid: _targetEid, // WHICH chain to read from
      isBlockNum: false, // Use timestamp (not block number)
      blockNumOrTimestamp: uint64(block.timestamp + _readDelay), // WHEN to read the state (current time)
      confirmations: 15, // HOW many confirmations to wait for
      to: _targetContractAddress, // WHERE - the contract address to call
      callData: callData // WHAT - the function call to execute
     });

    return ReadCodecV1.encode(0, readRequests);
  }

  function _lzReceive(
    Origin calldata, /*_origin*/
    bytes32 _guid,
    bytes calldata _message,
    address, /*_executor*/
    bytes calldata /*_extraData*/
  ) internal override {
    bool linked = abi.decode(_message, (bool));

    if (!linked) return;

    _completeLink(messageToTargetChainId[_guid]);
  }

  function _completeLink(uint64 _chainId) internal {
    PeerStatus storage status = peerStatusList[_chainId];

    if (status.peer == bytes32(0)) {
      return;
    }

    status.succeed = true;
    emit PeerLinkingCompleted(_chainId);
  }

  function setReadChannel(uint32 _channelId, bool _active) public override onlyOwner {
    _setPeer(_channelId, _active ? AddressCast.toBytes32(address(this)) : bytes32(0));
    READ_CHANNEL = _channelId;
  }

  function getPeerStatus(uint64 _chainId) external view returns (PeerStatus memory) {
    return peerStatusList[_chainId];
  }

  function IsValidDestination(uint32 _dstEid) external view override returns (bool) {
    return peerStatusList[layerZeroToChainId[_dstEid]].succeed;
  }

  receive() external payable {
    revert("Blocked Direct Native Payment");
  }
}
