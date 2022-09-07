// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

contract ReentrantLock {
    bool locked;
    modifier lock() {
        require(locked);
        locked = true;
        _;
        locked = false;
    }
}

contract Administrable {
    address public admin;
    address public pendingAdmin;
    event LogSetAdmin(address admin);
    event LogTransferAdmin(address oldadmin, address newadmin);
    event LogAcceptAdmin(address admin);

    function setAdmin(address admin_) internal {
        admin = admin_;
        emit LogSetAdmin(admin_);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        address oldAdmin = pendingAdmin;
        pendingAdmin = newAdmin;
        emit LogTransferAdmin(oldAdmin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin);
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit LogAcceptAdmin(admin);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }
}

contract Pausable is Administrable {
    bool public paused;

    /// @dev pausable control function
    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    /// @dev set paused flag to pause/unpause functions
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
    }
}

contract MPCControllable {
    address public mpc;
    address public pendingMPC;

    event ChangeMPC(
        address indexed oldMPC,
        address indexed newMPC,
        uint256 timestamp
    );
    event ApplyMPC(
        address indexed oldMPC,
        address indexed newMPC,
        uint256 timestamp
    );

    /// @dev Access control function
    modifier onlyMPC() {
        require(msg.sender == mpc, "only MPC");
        _;
    }

    /// @notice Change mpc
    function changeMPC(address _mpc) external onlyMPC {
        pendingMPC = _mpc;
        emit ChangeMPC(mpc, _mpc, block.timestamp);
    }

    /// @notice Apply mpc
    function applyMPC() external {
        require(msg.sender == pendingMPC);
        emit ApplyMPC(mpc, pendingMPC, block.timestamp);
        mpc = pendingMPC;
        pendingMPC = address(0);
    }
}

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

interface IAnyCallApp {
    function anyExecute(
        uint256 fromChainId,
        address sender,
        bytes calldata data,
        uint256 callNonce
    ) external returns (bool success, bytes memory result);

    function anyFallback(
        uint256 toChainId,
        address receiver,
        bytes calldata data,
        uint256 callNonce,
        bytes calldata reason
    ) external returns (bool success, bytes memory result);
}

// AnyCallExecutor interface of anycall executor
contract AnyCallExecutor {
    address anycallproxy;

    constructor(address anycallproxy_) {
        anycallproxy = anycallproxy_;
    }

    modifier onlyAnyCallProxy() {
        require(msg.sender == anycallproxy);
        _;
    }

    function appExec(
        uint256 fromChainId,
        address sender,
        address receiver,
        bytes calldata data,
        uint256 callNonce
    ) external onlyAnyCallProxy returns (bool success, bytes memory result) {
        return
            IAnyCallApp(receiver).anyExecute(
                fromChainId,
                sender,
                data,
                callNonce
            );
    }

    function appFallback(
        address sender,
        uint256 toChainId,
        address receiver,
        bytes calldata data,
        uint256 callNonce,
        bytes calldata reason
    ) external onlyAnyCallProxy returns (bool success, bytes memory result) {
        return
            IAnyCallApp(sender).anyFallback(
                toChainId,
                receiver,
                data,
                callNonce,
                reason
            );
    }
}

interface IAnyCallV7Proxy {
    function executor() external view returns (address);

    function anyCall(CallArgs memory _callArgs)
        external
        payable
        returns (bytes32 requestID);

    function retry(bytes32 requestID, ExecArgs calldata _execArgs, uint128 executionGasLimit, uint128 recursionGasLimit) external payable returns (bytes32);
}

/**
 * Convert between Uni gas and ETH
 * Make Uni gas pegged to USD
 */
abstract contract IUniGas {
    uint256 ethPrice; // in USD, decimal is 6

    function ethToUniGas(uint256 amount) public view returns (uint256) {
        return amount * ethPrice / 1 ether;
    }

    function uniGasToEth(uint256 amount) public view returns (uint256) {
        return amount / ethPrice * 1 ether;
    }
}

contract UniGas is IUniGas {
    constructor(address oracle) {
        trustedOracle = oracle;
    }

    address public trustedOracle;

    /// @notice set eth price from trusted oracle
    function setEthPrice(uint256 _ethPrice) public {
        require(msg.sender == trustedOracle);
        ethPrice = _ethPrice;
    }
}

/**
 * AnyCallV7Proxy
 * 1. Claim usage and pay fee on source chain
 * 2. Measure gas cost in Uni gas
 * 3. Store fail messages on source chain, allow fallback or retry
 */
contract AnyCallV7Proxy is
    IAnyCallV7Proxy,
    ReentrantLock,
    Pausable,
    MPCControllable
{
    /**
        0
        0 - autofallback -> 2
        0 - autofallback -> 1 - fallback -> 2
                                         -> 1
        0 - autofallback -> 1 - retry -> 0
     */
    uint8 constant Status_Sent = 0;
    uint8 constant Status_Fail = 1;
    uint8 constant Status_Fallback_Success = 2;
    uint8 constant Status_Retry_Success = 3;

    struct AnycallStatus {
        uint8 status;
        bytes32 execHash;
        bytes reason;
        uint256 timestamp;
    }

    event LogAnyCall(
        bytes32 indexed requestID,
        ExecArgs _execArgs
    );

    event LogAnyExec(
        bytes32 indexed requestID,
        ExecArgs _execArgs,
        uint256 _execNonce,
        bytes result
    );

    event LogAnyFallback(
        bytes32 indexed requestID,
        bytes32 indexed hash,
        ExecArgs _execArgs,
        uint256 _execNonce,
        bytes reason
    );

    event Fallback(
        bytes32 indexed requestID,
        ExecArgs _execArgs,
        bytes reason,
        bool success
    );

    event UpdateConfig(
        Config indexed config
    );

    event UpdateStoreGas(
        uint256 gasCost
    );

    event UpdateUniGasOracle(
        address indexed uniGas
    );

    event Deposit(
        address app,
        uint256 ethValue,
        uint256 uniGasValue
    );

    event Withdraw(
        address app,
        uint256 ethValue,
        uint256 uniGasValue
    );

    event Arrear(
        address app,
        int256 balance
    );

    uint256 public callNonce;
    uint256 public execNonce;

    address public executor;

    mapping(bytes32 => AnycallStatus) public anycallStatus;

    mapping(address => int256) public balanceOf; // receiver => UniGas balance
    mapping(address => uint256) public execFeeApproved; // receiver => execution fee approved
    mapping(address => uint256) public recrFeeApproved; // receiver => execution fee approved

    address public uniGas;

    struct Config {
        uint256 autoFallbackExecutionGasCost;
        uint256 expireTime;
    }

    uint256 public immutable gasOverhead; // source chain
    uint256 public immutable gasReserved; // dest chain execution gas reserved

    Config public config;

    struct Context {
        int256 uniGasLeft;
    }

    Context public context;

    /// @param _mpc mpc address
    /// @param autoFallbackExecutionGasCost Gas cost for auto fallback execution
    constructor(address _mpc, address _uniGas, uint256 _gasOverhead, uint256 autoFallbackExecutionGasCost, uint256 expireTime, uint256 _gasReserved) {
        mpc = _mpc;
        setAdmin(msg.sender);
        executor = address(new AnyCallExecutor(address(this)));
        uniGas = _uniGas;
        gasOverhead = _gasOverhead;
        gasReserved = _gasReserved;
        config = Config(autoFallbackExecutionGasCost, expireTime);
    }

    function setConfig(Config calldata _config) public onlyAdmin {
        config = _config;
        emit UpdateConfig(config);
    }

    function setUniGasOracle(address _uniGas) public onlyAdmin {
        uniGas = _uniGas;
        emit UpdateUniGasOracle(_uniGas);
    }

    function checkUniGas(uint256 destChainCost) internal {
        uint sourceChainCost = IUniGas(uniGas).ethToUniGas(tx.gasprice * (gasOverhead + config.autoFallbackExecutionGasCost));
        int256 totalCost = int256(sourceChainCost + destChainCost);

        if (context.uniGasLeft >= totalCost) {
            (bool success1,) = msg.sender.call{value: msg.value}("");
            require(success1);
            context.uniGasLeft -= int256(totalCost);
        } else {
            int256 fee = totalCost - (context.uniGasLeft > 0 ? context.uniGasLeft : int256(0));
            assert(fee > 0);
            context.uniGasLeft = 0;
            uint256 ethFee = IUniGas(uniGas).uniGasToEth(uint256(fee));
            (bool success2,) = mpc.call{value: ethFee}("");
            require(success2);
            if (ethFee < msg.value) {
                (bool success3,) = msg.sender.call{value: msg.value - ethFee}("");
                require(success3);
            }
        }
        assert(context.uniGasLeft >= 0);
    }

    /// @notice Calc request ID
    function calcRequestID(uint256 fromChainID, uint256 _callNonce)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(fromChainID, _callNonce));
    }

    /// @notice Calc exec args hash
    function calcExecArgsHash(ExecArgs memory args) public pure returns (bytes32) {
        return keccak256(abi.encode(args));
    }

    /// @notice Initiate request
    function anyCall(CallArgs memory _callArgs)
        external
        payable
        whenNotPaused
        returns (bytes32 requestID)
    {
        callNonce++;
        requestID = calcRequestID(block.chainid, callNonce);
        ExecArgs memory _execArgs = ExecArgs(uint128(block.chainid), uint160(msg.sender), _callArgs.toChainId, _callArgs.receiver, _callArgs.fallbackAddress, uint128(callNonce), _callArgs.executionGasLimit, _callArgs.recursionGasLimit, _callArgs.data);
        anycallStatus[requestID].execHash = calcExecArgsHash(_execArgs);
        anycallStatus[requestID].status = 0;
        anycallStatus[requestID].timestamp = block.timestamp;

        checkUniGas(_callArgs.executionGasLimit + _callArgs.recursionGasLimit);

        emit LogAnyCall(requestID, _execArgs);
        return requestID;
    }

    /// @notice Execute request
    function anyExec(ExecArgs calldata _execArgs)
        external
        lock
        whenNotPaused
        onlyMPC
    {
        execNonce++;
        bytes32 requestID = calcRequestID(
            _execArgs.fromChainId,
            _execArgs.callNonce
        );
        require(_execArgs.toChainId == block.chainid, "wrong chain id");
        bool success;
        bytes memory result;

        int recursionBudget = int128(_execArgs.recursionGasLimit) + int256(recrFeeApproved[address(_execArgs.receiver)]);
        context.uniGasLeft += recursionBudget;

        uint256 gasLimit = IUniGas(uniGas).uniGasToEth(uint256(_execArgs.executionGasLimit) + execFeeApproved[address(_execArgs.receiver)]) / tx.gasprice - gasReserved;

        uint256 executionGasUsage = gasleft();

        try
            AnyCallExecutor(executor).appExec{gas: gasLimit}(
                _execArgs.fromChainId,
                address(_execArgs.sender),
                address(_execArgs.receiver),
                _execArgs.data,
                _execArgs.callNonce
            )
        returns (bool succ, bytes memory res) {
            (success, result) = (succ, res);
        } catch Error(string memory reason) {
            result = bytes(reason);
        } catch (bytes memory reason) {
            result = reason;
        }

        assert(context.uniGasLeft >= 0);
        context.uniGasLeft = 0;

        if (success) {
            emit LogAnyExec(requestID, _execArgs, execNonce, result);
        } else {
            emit LogAnyFallback(requestID, calcExecArgsHash(_execArgs), _execArgs, execNonce, result);
        }

        executionGasUsage = executionGasUsage - gasleft();

        int executionUniGasUsage = int(IUniGas(uniGas).ethToUniGas(executionGasUsage * tx.gasprice));
        int recursionUsage = recursionBudget - context.uniGasLeft;

        execFeeApproved[address(_execArgs.receiver)] -= uint(executionUniGasUsage);
        balanceOf[address(_execArgs.receiver)] -= executionUniGasUsage;
        recrFeeApproved[address(_execArgs.receiver)] -= uint(recursionUsage);
        balanceOf[address(_execArgs.receiver)] -= recursionUsage;
        if (balanceOf[address(_execArgs.receiver)] < 0) {
            // Never runs
            emit Arrear(address(_execArgs.receiver), balanceOf[address(_execArgs.receiver)]);
        }
        context.uniGasLeft = 0;
    }

    /// @notice auto fallback
    /// this is called by mpc when the reflecting tx fails
    function autoFallback(ExecArgs calldata _execArgs, bytes calldata reason)
        external
        onlyMPC
        returns (bool success, bytes memory result)
    {
        bytes32 requestID = calcRequestID(_execArgs.fromChainId, _execArgs.callNonce);

        if (_execArgs.fallbackAddress == uint160(address(0))) {
            anycallStatus[requestID].status = 1;
            emit Fallback(requestID, _execArgs, reason, false);
            return (false, "no fallback address");
        }

        (success, result) = _fallback(_execArgs, reason, config.autoFallbackExecutionGasCost);
        if (success) {
            anycallStatus[requestID].status = 2; // auto fallback success
        } else {
            anycallStatus[requestID].status = 1; // auto fallback fail
            anycallStatus[requestID].reason = reason;
        }
        emit Fallback(requestID, _execArgs, reason, success);
        return (success, result);
    }

    /// @notice call app fallback function
    /// this is called by users directly or via contracts
    function anyFallback(bytes32 requestID, ExecArgs calldata _execArgs) external payable returns (bool success, bytes memory result) {
        require(requestID == calcRequestID(_execArgs.fromChainId, _execArgs.callNonce),  "request ID not match");
        require(_execArgs.fromChainId == block.chainid, "wrong chain id");
        require(_execArgs.callNonce <= callNonce, "wrong nonce");
        require(anycallStatus[requestID].status == 1, "can not retry succeeded request");
        require(anycallStatus[requestID].timestamp + config.expireTime >= block.timestamp, "request is expired");
        require(anycallStatus[requestID].execHash == calcExecArgsHash(_execArgs), "wrong execution hash");

        (success,) = mpc.call{value: msg.value}("");
        require(success, "pay fallback fee failed");
        
        uint256 gasLimit = msg.value / tx.gasprice;
        (success, result) = _fallback(_execArgs, anycallStatus[requestID].reason, gasLimit);
        if (success) {
            anycallStatus[requestID].status = 2;
        }
        emit Fallback(requestID, _execArgs, anycallStatus[requestID].reason, success);
    }

    function _fallback(ExecArgs memory _execArgs, bytes memory reason, uint256 gasLimit) internal lock whenNotPaused returns (bool success, bytes memory result) {
        require(_execArgs.fromChainId == block.chainid, "wrong chain id");
        try
            AnyCallExecutor(executor).appFallback{gas: gasLimit}(
                address(_execArgs.fallbackAddress),
                _execArgs.toChainId,
                address(_execArgs.receiver),
                _execArgs.data,
                _execArgs.callNonce,
                reason
            )
        returns (bool succ, bytes memory res) {
            (success, result) = (succ, res);
        } catch Error(string memory _reason) {
            result = bytes(_reason);
        } catch (bytes memory _reason) {
            result = _reason;
        }
    }

    /// @notice Retry recorded request
    function retry(bytes32 requestID, ExecArgs calldata _execArgs, uint128 executionGasLimit, uint128 recursionGasLimit) external payable whenNotPaused returns (bytes32) {
        require(requestID == calcRequestID(_execArgs.fromChainId, _execArgs.callNonce),  "request ID not match");
        require(_execArgs.fromChainId == block.chainid, "wrong chain id");
        require(_execArgs.callNonce <= callNonce, "wrong nonce");
        require(anycallStatus[requestID].status == 1, "can not retry succeeded request");
        require(anycallStatus[requestID].timestamp + config.expireTime >= block.timestamp, "request is expired");
        require(anycallStatus[requestID].execHash == calcExecArgsHash(_execArgs), "wrong execution hash");

        anycallStatus[requestID].status = 0;

        checkUniGas(executionGasLimit + recursionGasLimit);
        callNonce++;
        requestID = calcRequestID(block.chainid, callNonce);
        ExecArgs memory _execArgs_2 = ExecArgs(uint128(block.chainid), uint160(msg.sender), _execArgs.toChainId, _execArgs.receiver, _execArgs.fallbackAddress, uint128(callNonce), executionGasLimit, recursionGasLimit, _execArgs.data);
        anycallStatus[requestID].execHash = calcExecArgsHash(_execArgs_2);
        anycallStatus[requestID].status = 0;
        emit LogAnyCall(requestID, _execArgs_2);
        return requestID;
    }

    function deposit(address app) payable public {
        uint256 uniGasAmount = IUniGas(uniGas).ethToUniGas(msg.value);
        balanceOf[app] += int256(uniGasAmount);
        (bool success,) = mpc.call{value: msg.value}("");
        require(success);
        emit Deposit(app, msg.value, uniGasAmount);
    }

    function withdraw(address app, uint256 amount) public {
        require(msg.sender == app, "not allowed");
        balanceOf[app] -= int256(amount);
        uint256 ethAmount = IUniGas(uniGas).uniGasToEth(amount);
        (bool success,) = app.call{value: ethAmount}("");
        require(success);
        emit Withdraw(app, ethAmount, amount);
    }
}