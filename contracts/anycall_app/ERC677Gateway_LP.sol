// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;

import "../ERC677Gateway.sol";
import "../interfaces/ITransfer.sol";

contract ERC677Gateway_LP is ERC677Gateway {

    constructor (address anyCallProxy, uint256 flag, address token) ERC677Gateway(anyCallProxy, flag, token) {}

    function _swapout(uint256 amount, address sender) internal override returns (bool) {
        return ITransfer(token).transferFrom(sender, address(this), amount);
    }

    function _swapin(uint256 amount, address receiver) internal override returns (bool) {
        return ITransfer(token).transferFrom(address(this), receiver, amount);
    }
}