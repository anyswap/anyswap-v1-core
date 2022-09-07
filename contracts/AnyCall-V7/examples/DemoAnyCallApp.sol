pragma solidity ^0.8.0;

import "../clients/AnyCallApp.sol";
import "../interfaces/Types.sol";

contract DemoAnyCallApp is AnyCallApp {
    uint128 public destChain;
    address public peer;
    uint128 public fee; // keep the same on both chains

    constructor (address anyCallProxy) AnyCallApp(anyCallProxy) {}

    function setPeer(uint128 destChain_, address peer_) external onlyAdmin {
        destChain = destChain_;
        peer = peer_;
        isApprovedSender[destChain][peer] = true;
    }

    function setFee(uint128 fee_) external onlyAdmin {
        fee = fee_;
    }

    uint256 private prevSentBlockNumber;
    uint256 public sentBlockNumber;

    uint256 public receivedBlockNumber;

    event ReceiveBlockInfo(uint256 blocknumber, uint256 timestamp);

    function _beforeSend() internal {
        prevSentBlockNumber = sentBlockNumber;
        sentBlockNumber = block.number;
    }

    /// @notice entrance
    /// @param times recursive call times
    function sendBlockInfo(uint128 times) public payable {
        _beforeSend();
        bytes memory data = abi.encodePacked(block.number, block.timestamp, times);
        _anyCall(
            CallArgs(
                destChain,
                uint160(peer),
                uint160(address(this)),
                fee,
                (times - 1) * fee,
                data
            )
        );
    }

    function receiveBlockInfo(uint256 blocknumber, uint256 timestamp) internal {
        receivedBlockNumber = blocknumber;
        emit ReceiveBlockInfo(blocknumber, timestamp);
    }

    function _anyExecute(
        uint256 fromChainID,
        address sender,
        bytes calldata data,
        uint256 callNonce
    ) internal override returns (bool success, bytes memory result) {
        (uint256 blocknumber, uint256 timestamp, uint128 times) = abi.decode(
            data,
            (uint256, uint256, uint128)
        );
        receiveBlockInfo(blocknumber, timestamp);
        sendBlockInfo(times - 1);
        return (true, "");
    }

    function _anyFallback(
        uint256 toChainId,
        address receiver,
        bytes calldata data,
        uint256 callNonce,
        bytes calldata reason
    ) internal override returns (bool success, bytes memory result) {
        (uint256 blocknumber, uint256 timestamp) = abi.decode(
            data,
            (uint256, uint256)
        );
        if (blocknumber == sentBlockNumber) {
            sentBlockNumber = prevSentBlockNumber;
        }
    }
}
