pragma solidity ^0.8.0;

import "./IAnyCallSender.sol";
import "./IAnyCallReceiver.sol";

interface IAnyCallApp is IAnyCallSender, IAnyCallReceiver {}