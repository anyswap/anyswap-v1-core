pragma solidity ^0.8.0;

interface IAnyCallSender {
    function anyFallback(
        uint256 toChainId,
        address receiver,
        bytes calldata data,
        uint256 callNonce,
        bytes calldata reason
    ) external returns (bool success, bytes memory result);
}