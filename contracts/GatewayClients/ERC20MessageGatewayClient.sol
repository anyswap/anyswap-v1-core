// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ERC20MessageGatewaySender.sol";
import "./IERC20MessageGatewayReceiver.sol";

abstract contract ERC20MessageGatewayClient is ERC20_Message_Gateway_Sender, IERC20_Message_Gateway_Receiver {
    constructor (address gateway_) {
        gateway = gateway_;
    }
}