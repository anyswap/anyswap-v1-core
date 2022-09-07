pragma solidity ^0.8.0;

import "./Types.sol";

interface IAnyCallProxyV7 {
    function executor() external view returns (address);

    function anyCall(CallArgs memory _callArgs)
        external
        payable
        returns (bytes32 requestID);

    function retry(
        bytes32 requestID,
        ExecArgs calldata _execArgs,
        uint128 executionGasLimit,
        uint128 recursionGasLimit
    ) external payable returns (bytes32);

    function deposit(address app) payable external;

    function withdraw(address app, uint256 amount) external returns(uint256 ethAmount);

    function approve(address app, uint256 execFeeAllowance_, uint256 recrFeeAllowance_) external;
}
