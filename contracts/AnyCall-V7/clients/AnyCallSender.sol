pragma solidity ^0.8.0;

import "../../Administrable.sol";
import "../interfaces/IAnyCallProxyV7.sol";
import "../interfaces/IAnyCallSender.sol";
import "../interfaces/Types.sol";

abstract contract AnyCallSender is Administrable, IAnyCallSender {
    address public anyCallProxy;

    modifier onlyExecutor() {
        require(msg.sender == IAnyCallProxyV7(anyCallProxy).executor());
        _;
    }

    constructor(address anyCallProxy_) {
        anyCallProxy = anyCallProxy_;
    }

    function setAnyCallProxy(address proxy) public onlyAdmin {
        anyCallProxy = proxy;
    }

    function _anyCall(CallArgs memory _callArgs) internal {
        IAnyCallProxyV7(anyCallProxy).anyCall{value: msg.value}(_callArgs);
    }

    function _anyFallback(
        uint256 toChainId,
        address receiver,
        bytes calldata data,
        uint256 callNonce,
        bytes calldata reason
    ) internal virtual returns (bool success, bytes memory result);

    function anyFallback(
        uint256 toChainId,
        address receiver,
        bytes calldata data,
        uint256 callNonce,
        bytes calldata reason
    )
        external
        override
        onlyExecutor
        returns (bool success, bytes memory result)
    {
        require(
            msg.sender == IAnyCallProxyV7(anyCallProxy).executor(),
            "not allowed"
        );
        return _anyFallback(toChainId, receiver, data, callNonce, reason);
    }
}
