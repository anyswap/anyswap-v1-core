// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;

import "../ERC20MessageGateway.sol";
import "../interfaces/ITransfer.sol";

contract ERC20MessageGateway_LP is ERC20MessageGateway {

    constructor (address anyCallProxy, uint256 flag, address token) ERC20MessageGateway(anyCallProxy, flag, token) {}

    function _swapout(uint256 amount, address sender) internal override returns (bool) {
        return ITransfer(token).transferFrom(sender, address(this), amount);
    }

    function _swapin(uint256 amount, address receiver) internal override returns (bool) {
        return ITransfer(token).transferFrom(address(this), receiver, amount);
    }
}