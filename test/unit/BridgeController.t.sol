// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.30;

import "../base/BaseTest.t.sol";
import { BridgeController, IController } from "src/BridgeController.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { IMessageLibManager } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { IBridge } from "src/interfaces/IBridge.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { MessagingParams } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract BridgeControllerTest is BaseTest {
  uint32 private constant READ_CHANNEL = 2;
  uint32 private constant TARGET_CHAIN = 3774;
  uint32 private constant TARGET_EID = 33;
  uint32 private constant GAS_LIMIT = 200_000;

  uint32 private constant LZ_ENDPOINT_ID = 332;
  bytes32 private constant PEER = bytes32("PEER");
  uint256 private constant LZ_FEE = 2_399_482;

  address private lzEndpoint;
  address private owner;
  address private bridge;
  address private caller;
  BridgeControllerHarness private underTest;

  function setUp() public {
    lzEndpoint = generateAddress("LZEndpoint");
    owner = generateAddress("Owner", 100e18);
    bridge = generateAddress("Bridge");
    caller = generateAddress("Caller", 100e18);
    _setupLayerZero();

    vm.mockCall(bridge, abi.encodeWithSelector(IBridge.estimateFee.selector), abi.encode(LZ_FEE));

    underTest = new BridgeControllerHarness(lzEndpoint, owner, bridge, READ_CHANNEL);
  }

  function _setupLayerZero() internal {
    vm.mockCall(lzEndpoint, abi.encodeWithSignature("setDelegate(address)"), abi.encode(true));

    vm.mockCall(
      lzEndpoint, abi.encodeWithSelector(ILayerZeroEndpointV2.quote.selector), abi.encode(MessagingFee(LZ_FEE, 0))
    );

    MessagingReceipt memory emptyMsg;
    vm.mockCall(lzEndpoint, abi.encodeWithSelector(ILayerZeroEndpointV2.send.selector), abi.encode(emptyMsg));
  }

  function test_setBridgePeer_asNonOwner_thenReverts() external prankAs(caller) {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    underTest.setBridgePeer(1, 1, bytes32(0), address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0));
  }

  function test_setBridgePeer_whenSamePeerInProgress_thenReverts() external prankAs(owner) {
    _mockPeeringProgress();

    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, bytes32(0), address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );

    IController.PeerStatus memory status = underTest.getPeerStatus(TARGET_CHAIN);

    status.requestTimeout = uint32(block.timestamp + 30 minutes);
    underTest.expose_PeerStatus(TARGET_CHAIN, status);

    vm.expectRevert(IController.PeerAlreadyExists.selector);
    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, PEER, address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );

    status.failures = 100;
    underTest.expose_PeerStatus(TARGET_CHAIN, status);

    vm.expectRevert(IController.PeerAlreadyExists.selector);
    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, PEER, address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );

    vm.warp(block.timestamp + 1 days);

    status.succeed = true;
    underTest.expose_PeerStatus(TARGET_CHAIN, status);

    vm.expectRevert(IController.PeerAlreadyExists.selector);
    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, PEER, address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );
  }

  function test_setBridgePeer_whenPeerExpiredFully_thenAllowNewPeer() external prankAs(owner) {
    _mockPeeringProgress();

    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, PEER, address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );

    IController.PeerStatus memory status = underTest.getPeerStatus(TARGET_CHAIN);

    status.failures = 100;
    vm.warp(block.timestamp + 1 days);
    underTest.expose_PeerStatus(TARGET_CHAIN, status);

    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, bytes32(0), address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );

    status = underTest.getPeerStatus(TARGET_CHAIN);

    assertEq(status.failures, 0);
    assertEq(status.requestTimeout, 1);
  }

  function test_setBridgePeer_thenSetStatus() external prankAs(owner) {
    _mockPeeringProgress();

    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, PEER, address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );
    IController.PeerStatus memory status = underTest.getPeerStatus(TARGET_CHAIN);

    assertEq(status.failures, 0);
    assertFalse(status.succeed);
    assertEq(status.requestTimeout, 1);
    assertEq(underTest.layerZeroToChainId(TARGET_EID), TARGET_CHAIN);
  }

  function test_validatePeer_whenRequestTimeoutIsNotOne_thenReverts() external prankAs(owner) {
    vm.expectRevert("Validation already sent");
    underTest.validatePeer(TARGET_CHAIN, GAS_LIMIT, "");
  }

  function test_validatePeer_whenNotEnoughFee_thenReverts() external prankAs(owner) {
    _mockPeeringProgress();

    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, PEER, address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );

    vm.expectRevert("Not enough native fee");
    underTest.validatePeer{ value: LZ_FEE * 2 - 1 }(TARGET_CHAIN, GAS_LIMIT, "");
  }

  function test_validatePeer_whenPeerAlreadySucceed_thenReverts() external prankAs(owner) {
    _mockPeeringProgress();

    _mockPeeringProgress();

    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, PEER, address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );

    underTest.validatePeer{ value: LZ_FEE * 2 }(TARGET_CHAIN, GAS_LIMIT, "");

    IController.PeerStatus memory status = underTest.getPeerStatus(TARGET_CHAIN);
    assertGt(status.requestTimeout, block.timestamp);
  }

  function test_retryBridgePeering_whenPeerNotSet_thenReverts() external prankAs(owner) {
    vm.expectRevert("Peer not set");
    underTest.retryBridgePeering(TARGET_CHAIN, GAS_LIMIT, "");
  }

  function test_retryBridgePeering_whenPeerAlreadySucceed_thenReverts() external prankAs(owner) {
    _mockPeeringProgress();
    underTest.expose_PeerStatus(
      TARGET_CHAIN, IController.PeerStatus(TARGET_CHAIN, TARGET_EID, PEER, uint32(block.timestamp + 1 days), 0, true)
    );

    vm.expectRevert("Peer already succeed");
    underTest.retryBridgePeering(TARGET_CHAIN, GAS_LIMIT, "");
  }

  function test_retryBridgePeering_whenRequestStillOngoing_thenReverts() external prankAs(owner) {
    _mockPeeringProgress();
    underTest.expose_PeerStatus(
      TARGET_CHAIN, IController.PeerStatus(TARGET_CHAIN, TARGET_EID, PEER, uint32(block.timestamp + 1 days), 0, false)
    );

    vm.expectRevert("Request still ongoing");
    underTest.retryBridgePeering(TARGET_CHAIN, GAS_LIMIT, "");
  }

  function test_retryBridgePeering_whenMaxRetryReached_thenReverts() external prankAs(owner) {
    _mockPeeringProgress();
    underTest.expose_PeerStatus(
      TARGET_CHAIN, IController.PeerStatus(TARGET_CHAIN, TARGET_EID, PEER, 1, underTest.MAX_RETRY_PEER(), false)
    );

    vm.expectRevert("Max retry reached");
    underTest.retryBridgePeering(TARGET_CHAIN, GAS_LIMIT, "");
  }

  function test_retryBridgePeering_whenNotEnoughFee_thenReverts() external prankAs(owner) {
    _mockPeeringProgress();
    underTest.expose_PeerStatus(TARGET_CHAIN, IController.PeerStatus(TARGET_CHAIN, TARGET_EID, PEER, 1, 0, false));

    vm.expectRevert("Not enough native fee");
    underTest.retryBridgePeering{ value: LZ_FEE * 2 - 1 }(TARGET_CHAIN, GAS_LIMIT, "");
  }

  function test_retryBridgePeering_whenSuccess_thenUpdateStatus() external prankAs(owner) {
    _mockPeeringProgress();

    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, PEER, address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );

    underTest.validatePeer{ value: LZ_FEE * 2 }(TARGET_CHAIN, GAS_LIMIT, "");

    vm.warp(block.timestamp + 1 days);

    underTest.retryBridgePeering{ value: LZ_FEE }(TARGET_CHAIN, GAS_LIMIT, "");

    IController.PeerStatus memory status = underTest.getPeerStatus(TARGET_CHAIN);
    assertEq(status.failures, 1);
    assertGt(status.requestTimeout, block.timestamp);
  }

  function test_completeLink_thenSetCompleted() external prankAs(owner) {
    _mockPeeringProgress();

    underTest.setBridgePeer(
      TARGET_CHAIN, TARGET_EID, PEER, address(0), address(0), new SetConfigParam[](0), new SetConfigParam[](0)
    );

    IController.PeerStatus memory status = underTest.getPeerStatus(TARGET_CHAIN);

    underTest.expose_completeLink(TARGET_CHAIN);

    status = underTest.getPeerStatus(TARGET_CHAIN);
    assertTrue(status.succeed);
  }

  function _mockPeeringProgress() internal {
    vm.mockCall(lzEndpoint, abi.encodeWithSelector(IMessageLibManager.setConfig.selector), abi.encode(true));
    vm.mockCall(bridge, abi.encodeWithSelector(IBridge.sendMessageAsController.selector), abi.encode(true));
  }

  function _expectLZSend(uint256 _fee, uint32 _toEndpoint, bytes memory _payload, bytes memory _option, address _refund)
    private
  {
    vm.expectCall(
      lzEndpoint,
      _fee,
      abi.encodeWithSelector(
        ILayerZeroEndpointV2.send.selector, MessagingParams(_toEndpoint, PEER, _payload, _option, false), _refund
      )
    );
  }
}

contract BridgeControllerHarness is BridgeController {
  constructor(address _lzEndpoint, address _owner, address _bridge, uint32 _readChannel)
    BridgeController(_lzEndpoint, _owner, _bridge, _readChannel)
  { }

  function expose_PeerStatus(uint64 _targetChainId, PeerStatus memory _status) external {
    peerStatusList[_targetChainId] = _status;
  }

  function expose_completeLink(uint64 _targetChainId) external {
    _completeLink(_targetChainId);
  }
}
