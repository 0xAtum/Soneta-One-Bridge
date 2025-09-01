// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.30;

import "../base/BaseTest.t.sol";
import { OneBridge, IBridge } from "src/OneBridge.sol";
import { NoApprovalERC20 as MockERC20 } from "test/mock/NoApprovalERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OApp, Origin, MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTCore.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppCore.sol";
import { MessagingParams } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import { IController } from "src/interfaces/IController.sol";

contract OneBridgeTest is BaseTest {
  using OptionsBuilder for bytes;

  uint32 private constant SONIC_CHAIN_ID = 146;
  uint32 private constant LZ_PEER_ID = 332;
  uint32 private constant LZ_GAS_LIMIT = 200_000;
  bytes32 private constant PEER = bytes32("PEER");
  uint256 private constant LZ_FEE = 2_399_482;

  address private bridgeController;
  address private owner;
  address private caller;
  MockERC20 private oneToken;
  address private lzEndpoint;

  OneBridgeHarness private underTest;

  function setUp() public {
    bridgeController = generateAddress("BridgeController");
    owner = generateAddress("Owner");
    oneToken = new MockERC20("OneToken", "ONE", 18);
    lzEndpoint = generateAddress("LZEndpoint");
    caller = generateAddress("Caller", 100e18);

    oneToken.mint(caller, 1_000_000e18);

    _setupMockLzEndpoint();

    vm.mockCall(bridgeController, abi.encodeWithSelector(IController.IsValidDestination.selector), abi.encode(true));

    vm.chainId(SONIC_CHAIN_ID);
    underTest = new OneBridgeHarness(address(oneToken), address(lzEndpoint), owner);

    vm.prank(owner);
    underTest.setBridgeController(bridgeController);

    vm.prank(bridgeController);
    underTest.setPeer(LZ_PEER_ID, PEER);
  }

  function _setupMockLzEndpoint() internal {
    vm.mockCall(lzEndpoint, abi.encodeWithSignature("setDelegate(address)"), abi.encode(true));

    vm.mockCall(
      lzEndpoint, abi.encodeWithSelector(ILayerZeroEndpointV2.quote.selector), abi.encode(MessagingFee(LZ_FEE, 0))
    );

    MessagingReceipt memory emptyMsg;
    vm.mockCall(lzEndpoint, abi.encodeWithSelector(ILayerZeroEndpointV2.send.selector), abi.encode(emptyMsg));
  }

  function test_constructor_whenOnSonic_givenNoOneToken_thenReverts() public {
    vm.chainId(SONIC_CHAIN_ID);
    vm.expectRevert(abi.encodeWithSelector(IBridge.MissingOneTokenAddress.selector, address(0)));
    new OneBridgeHarness(address(0), address(lzEndpoint), owner);
  }

  function test_setBridgeController_asNotOwner_thenReverts() public prankAs(caller) {
    underTest = new OneBridgeHarness(address(oneToken), address(lzEndpoint), owner);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    underTest.setBridgeController(bridgeController);
  }

  function test_setBridgeController_asOwner_whenAlreadySet_thenReverts() public prankAs(owner) {
    vm.expectRevert("BridgeController already set");
    underTest.setBridgeController(bridgeController);
  }

  function test_setBridgeController_asOwner_thenSuccess() public prankAs(owner) {
    underTest = new OneBridgeHarness(address(oneToken), address(lzEndpoint), owner);

    underTest.setBridgeController(bridgeController);
    assertEq(address(underTest.BRIDGE_CONTROLLER()), bridgeController);
  }

  function test_send_whenPeerNotSet_thenReverts() public {
    vm.mockCall(bridgeController, abi.encodeWithSelector(IController.IsValidDestination.selector), abi.encode(false));
    vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidDestinationBridge.selector, 146));
    underTest.send(LZ_PEER_ID, address(0), 1.25e18, 1.25e18, 0);
  }

  function test_send_whenReceiverIsContract_thenReverts() public prankAs(caller) {
    vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidReceiver.selector, address(underTest)));
    underTest.send{ value: LZ_FEE }(LZ_PEER_ID, address(underTest), 1.25e18, 1.25e18, 0);
  }

  function test_send_whenOnSonic_thenTransferToken() public prankAs(caller) {
    vm.chainId(SONIC_CHAIN_ID);

    underTest.send{ value: LZ_FEE }(LZ_PEER_ID, address(0), 1.25e18, 1.25e18, 0);

    assertEq(oneToken.balanceOf(address(underTest)), 1.25e18);
  }

  function test_send_whenNonSonic_thenBurnsToken() public prankAs(caller) {
    vm.chainId(SONIC_CHAIN_ID + 20);

    underTest.exposed_mint(caller, 1_000_000e18);

    uint256 balanceBefore = underTest.balanceOf(caller);

    underTest.send{ value: LZ_FEE }(LZ_PEER_ID, address(0), 1.25e18, 1.25e18, 0);

    assertEq(oneToken.balanceOf(address(underTest)), 0);
    assertEq(underTest.balanceOf(address(underTest)), 0);
    assertEq(underTest.balanceOf(caller), balanceBefore - 1.25e18);
  }

  function test_lzReceive_whenIsPeeringMessage_thenSetFlagTrue() public {
    Origin memory origin = Origin({ srcEid: LZ_PEER_ID, sender: PEER, nonce: 0 });
    bytes memory payload = abi.encode(address(0), 0, SONIC_CHAIN_ID);

    underTest.exposed_lzReceive(origin, payload);

    assertTrue(underTest.isChainLinked(SONIC_CHAIN_ID));
  }

  function test_lzReceive_whenOnSonic_thenTransferToken() public {
    vm.chainId(SONIC_CHAIN_ID);
    uint256 amount = 288.3e18;

    oneToken.mint(address(underTest), amount);

    uint256 balanceBefore = oneToken.balanceOf(caller);

    Origin memory origin = Origin({ srcEid: LZ_PEER_ID, sender: PEER, nonce: 0 });
    bytes memory payload = abi.encode(caller, underTest.exposed_toSD(amount), 0);

    underTest.exposed_lzReceive(origin, payload);

    assertEq(oneToken.balanceOf(address(underTest)), 0);
    assertEq(oneToken.balanceOf(address(caller)), balanceBefore + amount);
  }

  function test_lzReceive_whenNotOnSonic_thenMintToken() public {
    vm.chainId(SONIC_CHAIN_ID + 20);
    uint256 amount = 288.3e18;

    Origin memory origin = Origin({ srcEid: LZ_PEER_ID, sender: PEER, nonce: 0 });
    bytes memory payload = abi.encode(caller, underTest.exposed_toSD(amount), 0);

    underTest.exposed_lzReceive(origin, payload);

    assertEq(underTest.balanceOf(address(underTest)), 0);
    assertEq(underTest.balanceOf(address(caller)), amount);
  }
}

contract OneBridgeHarness is OneBridge {
  constructor(address _oneToken, address _lzEndpoint, address _admin) OneBridge(_oneToken, _lzEndpoint, _admin) { }

  function exposed_lzReceive(Origin calldata _origin, bytes calldata _payload) external {
    _lzReceive(_origin, bytes32("hello"), _payload, address(0), _payload);
  }

  function exposed_mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }

  function exposed_lzReceive(bytes32 _uuid, Origin calldata _origin, bytes calldata _payload) external payable {
    _lzReceive(_origin, _uuid, _payload, address(0), _payload);
  }

  function exposed_toLD(uint64 _amount) external view returns (uint256) {
    return _toLD(_amount);
  }

  function exposed_toSD(uint256 _amount) external view returns (uint64) {
    return _toSD(_amount);
  }
}
