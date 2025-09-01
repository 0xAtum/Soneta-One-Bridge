// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../BaseScript.sol";
import { BridgeController } from "src/BridgeController.sol";

import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IController } from "src/interfaces/IController.sol";

contract ConnectBridges is BaseScript {
  using OptionsBuilder for bytes;

  struct LayerZeroConfig {
    uint32 id;
    address endpointV2;
    address sendUln;
    address receiveUln;
    address readUln;
    address executioner;
    address[] DVNs;
    address[] DVNsRead;
    uint32[] DVNsReadChannels;
    uint32 chainId;
  }

  string private constant BRIDGE_CONTROLLER_NAME = "BridgeController";
  address private constant MS_SAFE_ADMIN = 0xf185BDa3d70079F181aae0486994633511A9121e;

  string[] private SUPPORTED_CHAINS = ["ethereum", "arbitrum", "sonic", "base", "bsc" /*"hyperliquid", /*"sei"*/ ];
  uint32[] private chainIdsToLink = [1, 42_161, 146, 8453, 56 /*999, 1329*/ ];

  function run() public override {
    for (uint32 x = 0; x < SUPPORTED_CHAINS.length; x++) {
      _changeNetwork(SUPPORTED_CHAINS[x]);
      _loadDeployedContractsInSimulation();

      address _bridgeController = _tryGetContractAddress(BRIDGE_CONTROLLER_NAME);
      require(_bridgeController != address(0), "BridgeController not deployed");

      uint32 chainToLink;
      for (uint32 i = 0; i < chainIdsToLink.length; i++) {
        chainToLink = chainIdsToLink[i];

        if (block.chainid == chainToLink) continue;

        IController.PeerStatus memory peerStatus =
          BridgeController(payable(_bridgeController)).getPeerStatus(chainToLink);
        // console.log("Is Connected", chainToLink, peerStatus.succeed);
        if (peerStatus.requestTimeout != 1) continue;

        (uint256 a, uint256 b) = BridgeController(payable(_bridgeController)).getLzFees(chainToLink, 200_000, "");

        vm.broadcast(_getDeployerPrivateKey());
        BridgeController(payable(_bridgeController)).validatePeer{ value: a + b }(chainToLink, 200_000, "");
      }

      vm.broadcast(_getDeployerPrivateKey());
      BridgeController(payable(_bridgeController)).transferOwnership(MS_SAFE_ADMIN);
    }
  }
}
