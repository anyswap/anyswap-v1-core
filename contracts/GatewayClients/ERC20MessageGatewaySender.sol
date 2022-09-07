// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../interfaces/Types.sol";
import "../interfaces/IERC20MessageGateway.sol";

abstract contract ERC20_Message_Gateway_Sender {
    address gateway;

    /// @dev User entrance demo
    function send(
        uint256 toChainID,
        uint256 amount,
        address receiver,
        address callTo
    ) external payable {
        SwapOutArgs memory swapargs = SwapOutArgs(toChainID, receiver, amount);

        bytes memory boundMessage = "any message";

        IERC20MessageGateway(gateway).SwapOut_and_call(
            swapargs,
            callTo,
            boundMessage
        );
    }
}
