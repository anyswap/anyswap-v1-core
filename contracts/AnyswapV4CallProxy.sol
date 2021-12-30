// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.6;

// MPC management means multi-party validation.
// MPC signing likes Multi-Signature is more secure than use private key directly.
abstract contract MPCManageable {
    address public mpc;
    address public pendingMPC;

    uint256 public constant delay = 2 days;
    uint256 public delayMPC;

    modifier onlyMPC() {
        require(msg.sender == mpc, "MPC: only mpc");
        _;
    }

    event LogChangeMPC(
        address indexed oldMPC,
        address indexed newMPC,
        uint256 indexed effectiveTime);

    event LogApplyMPC(
        address indexed oldMPC,
        address indexed newMPC,
        uint256 indexed applyTime);

    constructor(address _mpc) {
        require(_mpc != address(0), "MPC: mpc is the zero address");
        mpc = _mpc;
        emit LogChangeMPC(address(0), mpc, block.timestamp);
    }

    function changeMPC(address _mpc) external onlyMPC {
        require(_mpc != address(0), "MPC: mpc is the zero address");
        pendingMPC = _mpc;
        delayMPC = block.timestamp + delay;
        emit LogChangeMPC(mpc, pendingMPC, delayMPC);
    }

    function applyMPC() external {
        require(msg.sender == pendingMPC, "MPC: only pendingMPC");
        require(block.timestamp >= delayMPC, "MPC: time before delayMPC");
        emit LogApplyMPC(mpc, pendingMPC, block.timestamp);
        mpc = pendingMPC;
        pendingMPC = address(0);
        delayMPC = 0;
    }
}

// support limit operations to whitelist
abstract contract Whitelistable is MPCManageable {
    mapping(address => mapping(uint256 => mapping(address => bool))) isInWhitelist;
    mapping(address => mapping(uint256 =>address[])) whitelists;

    event LogSetWhitelist(address indexed from, uint256 indexed chainID, address indexed to, bool flag);

    modifier onlyFromWhitelist(address from) {
        require(isInWhitelist[address(this)][block.chainid][from], "AnyCall: caller is not in whitelist");
        _;
    }

    modifier onlyToWhitelist(address from, uint256 chainID, address[] memory to) {
        mapping(address => bool) storage map = isInWhitelist[from][chainID];
        for (uint256 i = 0; i < to.length; i++) {
            require(map[to[i]], "AnyCall: to address is not in whitelist");
        }
        _;
    }

    constructor(address _mpc) MPCManageable(_mpc) {
    }

    function whitelistLength(address from, uint256 chainID) external view returns (uint256) {
        return whitelists[from][chainID].length;
    }

    function whitelist(uint256 chainID, address to, bool flag) external {
        this.adminWhitelist(msg.sender, chainID, to, flag);
    }

    function whitelistCaller(address caller, bool flag) external onlyMPC {
        this.adminWhitelist(address(this), block.chainid, caller, flag);
    }

    function adminWhitelist(address from, uint256 chainID, address to, bool flag) external onlyMPC {
        require(isInWhitelist[from][chainID][to] != flag, "nothing change");
        address[] storage list = whitelists[from][chainID];
        if (flag) {
            list.push(to);
        } else {
            uint256 length = list.length;
            for (uint i = 0; i < length; i++) {
                if (list[i] == to) {
                    if (i + 1 < length) {
                        list[i] = list[length-1];
                    }
                    list.pop();
                }
            }
        }
        isInWhitelist[from][chainID][to] = flag;
        emit LogSetWhitelist(from, chainID, to, flag);
    }
}

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

abstract contract Billing is MPCManageable {
    address payable dao;

    constructor (address _dao) {
        dao = payable(_dao);
    }

    struct Price {
        address token;
        uint256 amount;
    }

    event LogPayment(address from, Price price);

    mapping(address => mapping(address => Price)) public priceList;
    mapping(address => bool) public payByContract;

    function setPrice(address from, address to, address token, uint256 price) public onlyMPC {
        priceList[from][to] = Price(token, price);
    }

    function getPrice(address from, address to, bytes[] memory data, uint256 toChainID) public view returns (Price memory) {
        return priceList[from][to];
    }

    function pay(address from, address[] memory to, bytes[] memory data, uint256 toChainID) internal {
        for (uint i=0; i<to.length; i++) {
            Price memory price = getPrice(from, to[i], data, toChainID);
            bool res = false;
            if (payByContract[from]) {
                res = IERC20(price.token).transferFrom(from, dao, price.amount);
            } else {
                res = IERC20(price.token).transferFrom(tx.origin, dao, price.amount);
            }
            require(res, "pay bill failed");
            emit LogPayment(from, price);
        }
    }
}

contract AnyCallProxy is Whitelistable, Billing {
    uint256 public immutable cID;

    event LogAnyCall(address indexed from, address[] to, bytes[] data,
                     address[] callbacks, uint256[] nonces, uint256 fromChainID, uint256 toChainID);
    event LogAnyExec(address indexed from, address[] to, bytes[] data, bool[] success, bytes[] result,
                     address[] callbacks, uint256[] nonces, uint256 fromChainID, uint256 toChainID);

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'AnyCall: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    constructor(address _mpc, address _dao) Whitelistable(_mpc) Billing(_dao) {
        cID = block.chainid;
    }

    /**
        @notice Trigger a cross-chain contract interaction
        @param to - list of addresses to call
        @param data - list of data payloads to send / call
        @param callbacks - the callbacks on the fromChainID to call
        `callback(address to, bytes data, uint256 nonces, uint256 fromChainID, bool success, bytes result)`
        @param nonces - the nonces (ordering) to include for the resulting callback
        @param toChainID - the recipient chain that will receive the events
    */
    function anyCall(
        address[] memory to,
        bytes[] memory data,
        address[] memory callbacks,
        uint256[] memory nonces,
        uint256 toChainID
    ) external onlyFromWhitelist(msg.sender) onlyToWhitelist(msg.sender, toChainID, to) {
        pay(msg.sender, to, data, toChainID);
        emit LogAnyCall(msg.sender, to, data, callbacks, nonces, cID, toChainID);
    }

    function anyCall(
        address from,
        address[] memory to,
        bytes[] memory data,
        address[] memory callbacks,
        uint256[] memory nonces,
        uint256 fromChainID
    ) external onlyMPC lock {
        require(from != address(this) && from != address(0), "AnyCall: FORBID");
        uint256 length = to.length;
        bool[] memory success = new bool[](length);
        bytes[] memory results = new bytes[](length);
        uint256 chainID = block.chainid;
        for (uint256 i = 0; i < length; i++) {
            address _to = to[i];
            if (isInWhitelist[from][chainID][_to]) {
                (success[i], results[i]) = _to.call{value:0}(data[i]);
            } else {
                (success[i], results[i]) = (false, "forbid calling");
            }
        }
        emit LogAnyExec(from, to, data, success, results, callbacks, nonces, fromChainID, cID);
    }
}