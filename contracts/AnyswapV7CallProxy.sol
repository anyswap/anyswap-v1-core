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
    uint256 toChainId;
    address receiver;
    address fallbackAddress;
    bytes data;
    uint8 feeMode;
}

struct ExecArgs {
    uint256 fromChainId;
    address sender;
    uint256 toChainId;
    address receiver;
    bool fallbackMode;
    bytes data;
    uint8 feeMode;
    uint256 callNonce;
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

// App's custome fee manager
interface IFeeManager {
    /// @notice returns estimated execution fee in ethers
    function estimateExecFee(CallArgs calldata _callArgs)
        external
        view
        returns (uint256);

    /// @notice returns estimated fallback fee in ethers
    function estimateFallbackFee(ExecArgs calldata _execArgs)
        external
        view
        returns (uint256);
}

interface IAnyCallV7Proxy {
    function executor() external view returns (address);

    function anyCall(CallArgs memory _callArgs)
        external
        payable
        returns (bytes32 requestID);

    function retryExec(bytes32 requestID) external payable;
}

contract AnyCallV7Proxy is
    IAnyCallV7Proxy,
    ReentrantLock,
    Pausable,
    MPCControllable
{
    struct RetryRecord {
        ExecArgs execArgs;
        bool success;
    }

    struct FallbackRecord {
        ExecArgs execArgs;
        bool success;
    }

    // Packed fee information (only 1 storage slot)
    struct FeeData {
        uint128 accruedFees;
        uint128 premium;
    }

    event LogAnyCall(
        bytes32 indexed requestID,
        CallArgs _callArgs,
        uint256 _callNonce
    );

    event LogAnyExec(
        bytes32 indexed requestID,
        ExecArgs _execArgs,
        uint256 _execNonce,
        bytes result
    );

    event LogAnyFallback(
        bytes32 indexed requestID,
        ExecArgs _execArgs,
        uint256 _execNonce,
        bytes reason
    );

    event LogToRetry(
        bytes32 indexed requestID,
        ExecArgs _execArgs,
        uint256 _execNonce
    );

    event LogRetryFail(
        bytes32 indexed requestID,
        ExecArgs _execArgs,
        uint256 _execNonce,
        bytes reason
    );

    event LogRetrySuccess(
        bytes32 indexed requestID,
        ExecArgs _execArgs,
        uint256 _execNonce,
        bytes result
    );

    event UpdatePremium(uint256 oldPremium, uint256 newPremium);

    uint256 public callNonce;
    uint256 public execNonce;

    address public executor;

    FeeData private _feeData;
    uint256 public minReserveBudget;
    mapping(address => uint256) public executionBudget;

    mapping(address => address) public feeManager; // app contract address => fee manager contract address

    mapping(bytes32 => RetryRecord) public retryExecRecords;
    mapping(bytes32 => FallbackRecord) public fallbackRecords;

    // Extra cost of execution (SSTOREs.SLOADs,ADDs,etc..)
    // TODO: analysis to verify the correct overhead gas usage
    uint256 constant EXECUTION_OVERHEAD = 100000;
    uint8 public constant FLAG_PAY_FEE_PRECHARGE = 0;
    uint8 public constant FLAG_PAY_FEE_CUSTOMIZED = 2;

    /// @dev Charge sender account for execution costs
    modifier chargeOnCall(CallArgs memory _callArgs) {
        if (_callArgs.feeMode == FLAG_PAY_FEE_CUSTOMIZED) {
            uint256 fee = IFeeManager(feeManager[msg.sender]).estimateExecFee(
                _callArgs
            );
            require(msg.value >= fee, "no enough fee");
            _feeData.accruedFees += uint128(fee);
            _;
        }
        return;
    }

    /// @dev Charge receiver account for execution costs
    modifier chargeOnReceive(ExecArgs memory _execArgs) {
        // Prepare charge fee on the destination chain
        if (_execArgs.feeMode == FLAG_PAY_FEE_PRECHARGE) {
            uint256 gasUsed;
            require(
                executionBudget[_execArgs.receiver] >= minReserveBudget,
                "less than min budget"
            );
            gasUsed = gasleft() + EXECUTION_OVERHEAD;

            _;

            if (gasUsed > 0) {
                uint256 totalCost = (gasUsed - gasleft()) *
                    (tx.gasprice + _feeData.premium);
                uint256 budget = executionBudget[_execArgs.receiver];
                require(budget > totalCost, "no enough budget");
                executionBudget[_execArgs.receiver] = budget - totalCost;
                _feeData.accruedFees += uint128(totalCost);
            }
        }
        return;
    }

    /// @dev Charge user for retry cost
    modifier chargeOnRetry(ExecArgs memory _execArgs) {
        uint256 gasUsed = gasleft() + EXECUTION_OVERHEAD;
        _;
        uint256 totalCost = (gasUsed - gasleft()) *
            (tx.gasprice + _feeData.premium);
        require(msg.value >= totalCost, "retry fee not enough");
        _feeData.accruedFees += uint128(totalCost);
    }

    /// @dev Charge user for fallback cost
    modifier chargeOnUserFallback(ExecArgs memory _execArgs) {
        uint256 gasUsed = gasleft() + EXECUTION_OVERHEAD;
        _;
        uint256 totalCost = (gasUsed - gasleft()) *
            (tx.gasprice + _feeData.premium);
        require(msg.value >= totalCost, "fallback fee not enough");
        _feeData.accruedFees += uint128(totalCost);
    }

    /// @dev Charge sender account for fallback execution costs
    modifier chargeOnMPCFallback(ExecArgs memory _execArgs) {
        if (_execArgs.feeMode == FLAG_PAY_FEE_PRECHARGE) {
            uint256 gasUsed;
            require(
                executionBudget[_execArgs.sender] >= minReserveBudget,
                "less than min budget"
            );
            gasUsed = gasleft() + EXECUTION_OVERHEAD;

            _;

            if (gasUsed > 0) {
                uint256 totalCost = (gasUsed - gasleft()) *
                    (tx.gasprice + _feeData.premium);
                uint256 budget = executionBudget[msg.sender];
                require(budget > totalCost, "no enough budget");
                executionBudget[msg.sender] = budget - totalCost;
                _feeData.accruedFees += uint128(totalCost);
            }
        }
        return;
    }

    constructor(address _mpc, uint128 _premium) {
        mpc = _mpc;
        _feeData.premium = _premium;
        setAdmin(msg.sender);

        emit UpdatePremium(0, _premium);
    }

    /// @notice Calc request ID
    function calcRequestID(uint256 fromChainID, uint256 _callNonce)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(fromChainID, _callNonce));
    }

    /// @notice Initiate request
    function anyCall(CallArgs calldata _callArgs)
        external
        payable
        whenNotPaused
        chargeOnCall(_callArgs)
        returns (bytes32 requestID)
    {
        callNonce++;
        requestID = calcRequestID(block.chainid, callNonce);
        emit LogAnyCall(requestID, _callArgs, callNonce);
        return requestID;
    }

    /// @notice Execute request
    function anyExec(ExecArgs calldata _execArgs)
        external
        lock
        whenNotPaused
        onlyMPC
        chargeOnReceive(_execArgs)
    {
        execNonce++;
        bytes32 requestID = calcRequestID(
            _execArgs.fromChainId,
            _execArgs.callNonce
        );
        require(_execArgs.toChainId == block.chainid, "wrong chain id");
        bool success;
        bytes memory result;

        try
            AnyCallExecutor(executor).appExec(
                _execArgs.fromChainId,
                _execArgs.sender,
                _execArgs.receiver,
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

        if (success) {
            emit LogAnyExec(requestID, _execArgs, execNonce, result);
        } else if (_execArgs.fallbackMode) {
            emit LogAnyFallback(requestID, _execArgs, execNonce, result);
        } else {
            retryExecRecords[requestID] = RetryRecord(_execArgs, false);
            emit LogToRetry(requestID, _execArgs, execNonce);
        }
    }

    /// @notice fallback
    function anyFallback(ExecArgs calldata _execArgs, bytes calldata reason)
        external
        onlyMPC
        chargeOnMPCFallback(_execArgs)
        returns (bool success, bytes memory result)
    {
        bytes32 requestID = calcRequestID(_execArgs.fromChainId, _execArgs.callNonce);
        if (_execArgs.feeMode == FLAG_PAY_FEE_CUSTOMIZED) {
            fallbackRecords[requestID] = FallbackRecord(_execArgs, false);
            return(false, bytes("fallback paused"));
        }
        (success, result) = _anyFallback(_execArgs, reason);
        if (!success) {
            fallbackRecords[requestID] = FallbackRecord(_execArgs, false);
        }
        return (success, result);
    }

    function anyFallback(bytes32 requrestID) external payable chargeOnUserFallback(fallbackRecords[requrestID].execArgs) returns (bool success, bytes memory result) {
        require(!fallbackRecords[requrestID].success, "can not retry succeeded fallback");
        (success, result) = _anyFallback(fallbackRecords[requrestID].execArgs, bytes(""));
        if (success) {
            fallbackRecords[requrestID].success = true;
        }
    }

    function _anyFallback(ExecArgs memory _execArgs, bytes memory reason) internal lock whenNotPaused returns (bool success, bytes memory result) {
        require(_execArgs.fallbackMode, "fallback not allowed");
        require(_execArgs.fromChainId == block.chainid, "wrong chain id");
        try
            AnyCallExecutor(executor).appFallback(
                _execArgs.sender,
                _execArgs.toChainId,
                _execArgs.receiver,
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
    function retryExec(bytes32 requestID) external payable lock whenNotPaused {
        RetryRecord storage retry = retryExecRecords[requestID];
        _retryExec(requestID, retry);
    }

    function _retryExec(bytes32 requestID, RetryRecord memory retry)
        internal
        chargeOnRetry(retry.execArgs)
    {
        execNonce++;
        require(retry.execArgs.toChainId == block.chainid, "wrong chain id");
        require(!retry.success, "can not retry succeeded request");
        bool success;
        bytes memory result;

        try
            AnyCallExecutor(executor).appExec(
                retry.execArgs.fromChainId,
                retry.execArgs.sender,
                retry.execArgs.receiver,
                retry.execArgs.data,
                retry.execArgs.callNonce
            )
        returns (bool succ, bytes memory res) {
            (success, result) = (succ, res);
        } catch Error(string memory reason) {
            result = bytes(reason);
        } catch (bytes memory reason) {
            result = reason;
        }

        if (success) {
            emit LogRetrySuccess(requestID, retry.execArgs, execNonce, result);
        } else {
            emit LogRetryFail(requestID, retry.execArgs, execNonce, result);
        }
    }

    /// @notice Set anycall executor
    function setExecutor(address _executor) external onlyMPC {
        executor = _executor;
    }

    /// @notice Approve fee manager
    function approveFeeManager(address app, address feeManager_) external onlyAdmin {
        feeManager[app] = feeManager_;
    }

    /// @notice Get the total accrued fees in native currency
    /// @dev Fees increase when executing cross chain requests
    function accruedFees() external view returns (uint128) {
        return _feeData.accruedFees;
    }

    /// @notice Get the gas premium cost
    /// @dev This is similar to priority fee in eip-1559, except instead of going
    ///     to the miner it is given to the MPC executing cross chain requests
    function premium() external view returns (uint128) {
        return _feeData.premium;
    }

    /// @notice Set the premimum for cross chain executions
    /// @param _premium The premium per gas
    function setPremium(uint128 _premium) external onlyAdmin {
        emit UpdatePremium(_feeData.premium, _premium);
        _feeData.premium = _premium;
    }

    /// @notice Withdraw all accrued execution fees
    /// @dev The MPC is credited in the native currency
    function withdrawAccruedFees() external {
        uint256 fees = _feeData.accruedFees;
        _feeData.accruedFees = 0;
        (bool success, ) = mpc.call{value: fees}("");
        require(success);
    }
}
