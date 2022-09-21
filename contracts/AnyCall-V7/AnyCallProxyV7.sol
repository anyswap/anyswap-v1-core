// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./OwnableUpgradeable.sol";

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
}

interface IUniGas {
    function ethToUniGas(uint256 amount)
        external
        view
        virtual
        returns (uint256);

    function uniGasToEth(uint256 amount)
        external
        view
        virtual
        returns (uint256);
}

/**
 * AnyCallProxyV7
 */
contract AnyCallProxyV7 is
    IAnyCallProxyV7,
    ReentrantLock,
    Pausable,
    MPCControllable,
    OwnableUpgradeable
{
    /**
        AnyCall task status graph
        0 - execution success -> 0
          - autofallback success -> 2
          - autofallback fail -> 1
          - autofallback not allowed -> 1

        1 - fallback success -> 2
          - fallback fail -> 1
          - retry -> 0
     */
    uint8 constant Status_Sent = 0;
    uint8 constant Status_Fail = 1;
    uint8 constant Status_Fallback_Success = 2;

    struct AnycallStatus {
        uint8 status;
        bytes32 execHash;
        bytes reason;
        uint256 timestamp;
    }

    event LogAnyCall(bytes32 indexed requestID, ExecArgs _execArgs);

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

    event UpdateConfig(Config indexed config);

    event UpdateStoreGas(uint256 gasCost);

    event UpdateUniGasOracle(address indexed uniGas);

    event Deposit(address app, uint256 ethValue, uint256 uniGasValue);

    event Withdraw(address app, uint256 ethValue, uint256 uniGasValue);

    event Approved(
        address app,
        uint256 execFeeAllowance,
        uint256 recrFeeAllowance
    );

    event Arrear(address app, int256 balance);

    uint256 public callNonce;
    uint256 public execNonce;

    address public executor;

    mapping(bytes32 => AnycallStatus) public anycallStatus;

    mapping(address => int256) public balanceOf; // receiver => UniGas balance
    mapping(address => uint256) public execFeeAllowance; // receiver => execution fee approved
    mapping(address => uint256) public recrFeeAllowance; // receiver => execution fee approved

    address public uniGas;

    struct Config {
        uint256 autoFallbackExecutionGasCost;
    }

    uint256 public gasOverhead; // source chain
    uint256 public gasReserved; // dest chain execution gas reserved

    Config public config;

    struct Context {
        int256 uniGasLeft;
    }

    Context public context;

    modifier onlyInternal() {
        require(msg.sender == address(this));
        _;
    }

    /// @param _mpc mpc address
    /// @param autoFallbackExecutionGasCost Gas cost for auto fallback execution
    function initiate(
        address _mpc,
        address _uniGas,
        uint256 _gasOverhead,
        uint256 autoFallbackExecutionGasCost,
        uint256 _gasReserved
    ) public initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
        mpc = _mpc;
        setAdmin(msg.sender);
        executor = address(new AnyCallExecutor(address(this)));
        uniGas = _uniGas;
        gasOverhead = _gasOverhead;
        gasReserved = _gasReserved;
        config = Config(autoFallbackExecutionGasCost);
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
        uint256 sourceChainCost = IUniGas(uniGas).ethToUniGas(
            tx.gasprice * (gasOverhead + config.autoFallbackExecutionGasCost)
        );
        int256 totalCost = int256(sourceChainCost + destChainCost);

        if (context.uniGasLeft >= totalCost) {
            (bool success1, ) = msg.sender.call{value: msg.value}("");
            require(success1);
            context.uniGasLeft -= int256(totalCost);
        } else {
            int256 fee = totalCost -
                (context.uniGasLeft > 0 ? context.uniGasLeft : int256(0));
            assert(fee > 0);
            context.uniGasLeft = 0;
            uint256 ethFee = IUniGas(uniGas).uniGasToEth(uint256(fee));
            (bool success2, ) = mpc.call{value: ethFee}("");
            require(success2);
            if (ethFee < msg.value) {
                (bool success3, ) = msg.sender.call{value: msg.value - ethFee}(
                    ""
                );
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
    function calcExecArgsHash(ExecArgs memory args)
        public
        pure
        returns (bytes32)
    {
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
        ExecArgs memory _execArgs = ExecArgs(
            uint128(block.chainid),
            uint160(msg.sender),
            _callArgs.toChainId,
            _callArgs.receiver,
            _callArgs.fallbackAddress,
            uint128(callNonce),
            _callArgs.executionGasLimit,
            _callArgs.recursionGasLimit,
            _callArgs.data
        );
        anycallStatus[requestID].execHash = calcExecArgsHash(_execArgs);
        anycallStatus[requestID].status = Status_Sent;
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

        int256 recursionBudget = int128(_execArgs.recursionGasLimit) +
            int256(recrFeeAllowance[address(_execArgs.receiver)]);
        context.uniGasLeft += recursionBudget;

        uint256 gasLimit = IUniGas(uniGas).uniGasToEth(
            uint256(_execArgs.executionGasLimit) +
                execFeeAllowance[address(_execArgs.receiver)]
        ) /
            tx.gasprice -
            gasReserved;

        uint256 executionGasUsage = gasleft();

        try
            this._anyExec(_execArgs, gasLimit)
        returns (bool succ, bytes memory res) {
            (success, result) = (succ, res);
        } catch Error(string memory reason) {
            result = bytes(reason);
        } catch (bytes memory reason) {
            result = reason;
        }

        if (success) {
            emit LogAnyExec(requestID, _execArgs, execNonce, result);
        } else {
            emit LogAnyFallback(
                requestID,
                calcExecArgsHash(_execArgs),
                _execArgs,
                execNonce,
                result
            );
        }

        executionGasUsage = executionGasUsage - gasleft();

        int256 appExecutionUniGasUsage = int256(IUniGas(uniGas).ethToUniGas(executionGasUsage * tx.gasprice)); // asserting positive
        appExecutionUniGasUsage -= int128(_execArgs.executionGasLimit); // pos or neg

        // update app exec fee allowance, decrease only
        execFeeAllowance[address(_execArgs.receiver)] -= appExecutionUniGasUsage > 0 ? uint256(appExecutionUniGasUsage) : 0;

        int256 appRecursionUsage = recursionBudget - context.uniGasLeft;
        appRecursionUsage -= int128(_execArgs.recursionGasLimit); // pos or neg

        // update app recr fee allowance, decrease only
        recrFeeAllowance[address(_execArgs.receiver)] -= appRecursionUsage > 0 ? uint256(appRecursionUsage) : 0;

        // update app fee balance, increase or decrease
        balanceOf[address(_execArgs.receiver)] -= appExecutionUniGasUsage;
        balanceOf[address(_execArgs.receiver)] -= appRecursionUsage;

        context.uniGasLeft = 0;

        if (balanceOf[address(_execArgs.receiver)] < 0) {
            // Never runs
            emit Arrear(
                address(_execArgs.receiver),
                balanceOf[address(_execArgs.receiver)]
            );
        }
        context.uniGasLeft = 0;
    }

    /**
     * @dev _anyExec is an external function modified as onlyInternal
     * because it should run in try-catch block.
     * It reverts when appExec fail or uni gas check fail.
     */
    function _anyExec(ExecArgs calldata _execArgs, uint256 gasLimit) external onlyInternal returns (bool succ, bytes memory res) {
        (succ, res) = AnyCallExecutor(executor).appExec{gas: gasLimit}(
            _execArgs.fromChainId,
            address(_execArgs.sender),
            address(_execArgs.receiver),
            _execArgs.data,
            _execArgs.callNonce
        );
        assert(context.uniGasLeft >= 0);
        return (succ, res);
    }

    /// @notice auto fallback
    /// this is called by mpc when the reflecting tx fails
    function autoFallback(ExecArgs calldata _execArgs, bytes calldata reason)
        external
        onlyMPC
        returns (bool success, bytes memory result)
    {
        bytes32 requestID = calcRequestID(
            _execArgs.fromChainId,
            _execArgs.callNonce
        );

        if (_execArgs.fallbackAddress == uint160(address(0))) {
            anycallStatus[requestID].status = Status_Fail;
            emit Fallback(requestID, _execArgs, reason, false);
            return (false, "no fallback address");
        }

        (success, result) = _fallback(
            _execArgs,
            reason,
            config.autoFallbackExecutionGasCost
        );
        if (success) {
            anycallStatus[requestID].status = Status_Fallback_Success; // auto fallback success
        } else {
            anycallStatus[requestID].status = Status_Fail; // auto fallback fail
            anycallStatus[requestID].reason = reason;
        }
        emit Fallback(requestID, _execArgs, reason, success);
        return (success, result);
    }

    /// @notice call app fallback function
    /// this is called by users directly or via contracts
    function anyFallback(bytes32 requestID, ExecArgs calldata _execArgs)
        external
        payable
        returns (bool success, bytes memory result)
    {
        require(
            requestID ==
                calcRequestID(_execArgs.fromChainId, _execArgs.callNonce),
            "request ID not match"
        );
        require(_execArgs.fromChainId == block.chainid, "wrong chain id");
        require(_execArgs.callNonce <= callNonce, "wrong nonce");
        require(
            anycallStatus[requestID].status == Status_Fail,
            "can not retry succeeded request"
        );
        require(
            anycallStatus[requestID].execHash == calcExecArgsHash(_execArgs),
            "wrong execution hash"
        );

        (success, ) = mpc.call{value: msg.value}("");
        require(success, "pay fallback fee failed");

        uint256 gasLimit = msg.value / tx.gasprice;
        (success, result) = _fallback(
            _execArgs,
            anycallStatus[requestID].reason,
            gasLimit
        );
        if (success) {
            anycallStatus[requestID].status = Status_Fallback_Success;
        }
        emit Fallback(
            requestID,
            _execArgs,
            anycallStatus[requestID].reason,
            success
        );
    }

    function _fallback(
        ExecArgs memory _execArgs,
        bytes memory reason,
        uint256 gasLimit
    ) internal lock whenNotPaused returns (bool success, bytes memory result) {
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
    function retry(
        bytes32 requestID,
        ExecArgs calldata _execArgs,
        uint128 executionGasLimit,
        uint128 recursionGasLimit
    ) external payable whenNotPaused returns (bytes32) {
        require(
            requestID ==
                calcRequestID(_execArgs.fromChainId, _execArgs.callNonce),
            "request ID not match"
        );
        require(_execArgs.fromChainId == block.chainid, "wrong chain id");
        require(_execArgs.callNonce <= callNonce, "wrong nonce");
        require(
            anycallStatus[requestID].status == 1,
            "can not retry succeeded request"
        );
        require(
            anycallStatus[requestID].execHash == calcExecArgsHash(_execArgs),
            "wrong execution hash"
        );

        anycallStatus[requestID].status = 0;

        checkUniGas(executionGasLimit + recursionGasLimit);
        callNonce++;
        requestID = calcRequestID(block.chainid, callNonce);
        ExecArgs memory _execArgs_2 = ExecArgs(
            uint128(block.chainid),
            uint160(msg.sender),
            _execArgs.toChainId,
            _execArgs.receiver,
            _execArgs.fallbackAddress,
            uint128(callNonce),
            executionGasLimit,
            recursionGasLimit,
            _execArgs.data
        );
        anycallStatus[requestID].execHash = calcExecArgsHash(_execArgs_2);
        anycallStatus[requestID].status = Status_Sent;
        emit LogAnyCall(requestID, _execArgs_2);
        return requestID;
    }

    function deposit(address app) public payable {
        uint256 uniGasAmount = IUniGas(uniGas).ethToUniGas(msg.value);
        balanceOf[app] += int256(uniGasAmount);
        (bool success, ) = mpc.call{value: msg.value}("");
        require(success);
        emit Deposit(app, msg.value, uniGasAmount);
    }

    function withdraw(address app, uint256 amount)
        public
        returns (uint256 ethAmount)
    {
        require(msg.sender == app, "not allowed");
        balanceOf[app] -= int256(amount);
        ethAmount = IUniGas(uniGas).uniGasToEth(amount);
        (bool success, ) = app.call{value: ethAmount}("");
        require(success);
        emit Withdraw(app, ethAmount, amount);
        return ethAmount;
    }

    function approve(
        address app,
        uint256 execFeeAllowance_,
        uint256 recrFeeAllowance_
    ) external {
        require(msg.sender == app, "not allowed");
        execFeeAllowance[app] = execFeeAllowance_;
        recrFeeAllowance[app] = recrFeeAllowance_;
        emit Approved(app, execFeeAllowance_, recrFeeAllowance_);
    }
}
