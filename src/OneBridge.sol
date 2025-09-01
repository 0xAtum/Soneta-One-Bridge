// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IBridge } from "./interfaces/IBridge.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { SendParam, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import { MessagingFee, MessagingReceipt, Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessagingParams } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { IController } from "./interfaces/IController.sol";

/**
 * @title OneBridge
 * @notice Bridged Version of One Token.
 * @custom:export abi
 */
contract OneBridge is OFT, IBridge {
  using OptionsBuilder for bytes;

  uint32 public constant DEFAULT_GAS_LIMIT = 200_000;
  uint64 public constant ORIGIN_CHAIN = 146; //SONIC

  address public immutable ONE_TOKEN;
  address public BRIDGE_CONTROLLER;

  mapping(uint64 => bool) private linkReceived;

  modifier OnlyController() {
    require(msg.sender == BRIDGE_CONTROLLER, "Error: Only Controller can call this function");
    _;
  }

  constructor(address _oneToken, address _lzEndpoint, address _admin)
    OFT("Omnichain ONE", "oONE", _lzEndpoint, address(this))
    Ownable(_admin)
  {
    if (block.chainid == ORIGIN_CHAIN) {
      ONE_TOKEN = _oneToken;
      require(ONE_TOKEN != address(0), MissingOneTokenAddress());
    }
  }

  function setBridgeController(address _bridgeController) external onlyOwner {
    require(address(BRIDGE_CONTROLLER) == address(0), "BridgeController already set");

    BRIDGE_CONTROLLER = _bridgeController;
    endpoint.setDelegate(_bridgeController);
  }

  function send(SendParam calldata, MessagingFee calldata, address)
    external
    payable
    override
    returns (MessagingReceipt memory, OFTReceipt memory)
  {
    revert InvalidFunctionUseOtherSimilarName();
  }

  function send(uint32 _dstEid, address _to, uint256 _amountIn, uint256 _minAmountOut, uint32 _lzGasLimit)
    external
    payable
    returns (MessagingReceipt memory msgReceipt)
  {
    require(IController(BRIDGE_CONTROLLER).IsValidDestination(_dstEid), InvalidDestinationBridge());

    if (_to == address(0)) {
      _to = msg.sender;
    }

    require(_to != address(this), InvalidReceiver());

    (uint256 amountSentLD,) = _debitView(_amountIn, _minAmountOut, _dstEid);

    if (block.chainid == ORIGIN_CHAIN) {
      IERC20(ONE_TOKEN).transferFrom(msg.sender, address(this), amountSentLD);
    } else {
      _burn(msg.sender, amountSentLD);
    }

    return _sendMessage(_dstEid, _to, amountSentLD, _lzGasLimit, payable(msg.sender));
  }

  function sendMessageAsController(uint32 _dstEid, uint32 _gasLimit, address _refundTo)
    external
    payable
    override
    OnlyController
  {
    _sendMessage(_dstEid, address(0), 0, _gasLimit, _refundTo);
  }

  function _sendMessage(uint32 _dstEid, address _to, uint256 _amountSentLD, uint32 _lzGasLimit, address _refundTo)
    internal
    returns (MessagingReceipt memory msgReceipt_)
  {
    if (_lzGasLimit == 0) {
      _lzGasLimit = DEFAULT_GAS_LIMIT;
    }

    bytes memory option = OptionsBuilder.newOptions().addExecutorLzReceiveOption(_lzGasLimit, 0);
    bytes memory payload = _generateMessage(_to, _amountSentLD);

    MessagingFee memory fee = _estimateFee(_dstEid, payload, option);
    require(fee.nativeFee <= msg.value, NotEnoughNativeToPayLayerZeroFee());

    msgReceipt_ = _lzSend(_dstEid, payload, option, fee, _refundTo);

    emit OFTSent(msgReceipt_.guid, _dstEid, msg.sender, _amountSentLD, _amountSentLD);
    return msgReceipt_;
  }

  function _lzReceive(
    Origin calldata _origin,
    bytes32 _guid,
    bytes calldata _message,
    address, /*_executor*/ // @dev unused in the default implementation.
    bytes calldata /*_extraData*/ // @dev unused in the default implementation.
  ) internal virtual override {
    (address to, uint64 amountReceived, uint64 sourceChainId) = abi.decode(_message, (address, uint64, uint64));

    // Receiving a zero address from users in lzReceive should not occur. However, if it does happen, it won't cause any
    // issues.
    if (to == address(0)) {
      linkReceived[sourceChainId] = true;
      return;
    }

    uint256 amountToSend = _toLD(amountReceived);

    if (block.chainid == ORIGIN_CHAIN) {
      IERC20(ONE_TOKEN).transfer(to, amountToSend);
    } else {
      amountToSend = _credit(to, amountToSend, _origin.srcEid);
    }

    emit OneBridged(sourceChainId, to, amountReceived);
    emit OFTReceived(_guid, _origin.srcEid, to, amountToSend);
  }

  function _generateMessage(address _to, uint256 _amount) internal view virtual returns (bytes memory) {
    return abi.encode(_to, _toSD(_amount), uint64(block.chainid));
  }

  function estimateFee(uint32 _dstEid, uint256 _amount, uint32 _lzGasLimit) external view override returns (uint256) {
    if (_lzGasLimit == 0) {
      _lzGasLimit = DEFAULT_GAS_LIMIT;
    }

    bytes memory option = OptionsBuilder.newOptions().addExecutorLzReceiveOption(_lzGasLimit, 0);
    (uint256 amountSentLD,) = _debitView(_amount, _amount, _dstEid);

    bytes memory payload = _generateMessage(msg.sender, amountSentLD);

    return _estimateFee(_dstEid, payload, option).nativeFee;
  }

  function _estimateFee(uint32 _dstEid, bytes memory _payload, bytes memory _option)
    internal
    view
    returns (MessagingFee memory)
  {
    return _quote(_dstEid, _payload, _option, false);
  }

  function setPeer(uint32 _eid, bytes32 _peer) public override OnlyController {
    _setPeer(_eid, _peer);
  }

  function _previewQuote(
    uint32 _dstEid,
    bytes32 _peer,
    bytes memory _message,
    bytes memory _options,
    bool _payInLzToken
  ) internal view returns (MessagingFee memory fee) {
    return endpoint.quote(MessagingParams(_dstEid, _peer, _message, _options, _payInLzToken), address(this));
  }

  function isChainLinked(uint64 _chainId) external view override returns (bool) {
    return linkReceived[_chainId];
  }
}
