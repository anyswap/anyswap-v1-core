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
        return amount * 1 ether / ethPrice;
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