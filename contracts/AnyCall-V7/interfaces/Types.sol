pragma solidity ^0.8.0;

struct CallArgs {
    uint128 toChainId;
    uint160 receiver;
    uint160 fallbackAddress;
    uint128 executionGasLimit;
    uint128 recursionGasLimit;
    bytes data;
}

struct ExecArgs {
    uint128 fromChainId;
    uint160 sender;
    uint128 toChainId;
    uint160 receiver;
    uint160 fallbackAddress;
    uint128 callNonce;
    uint128 executionGasLimit;
    uint128 recursionGasLimit;
    bytes data;
}
