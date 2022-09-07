// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../interfaces/Types.sol";

interface IERC20_Message_Gateway_Receiver {
    // onlyGateway
    // verify boudnMessageSender if boudnMessage is nontradable
    function handleMessage(
        SwapOutArgs memory swapargs,
        address boudnMessageSender,
        bytes memory boundMessage,
        uint256 nonce
    ) external returns (bool success);
}
