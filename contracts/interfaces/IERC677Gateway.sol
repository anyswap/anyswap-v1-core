// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./Types.sol";

interface IERC677Gateway {
    function token() external view returns (address);
    function SwapOut_and_call(SwapOutArgs memory swapArgs, bytes memory boundMessage) external payable returns (uint256 swapoutSeq);
}