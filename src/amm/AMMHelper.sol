// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AMMHelper
 * @author Gemini
 * @dev A library for common mathematical calculations used by the MarketAMM.
 * It provides functions for calculating square roots and the value of LP tokens.
 */
library AMMHelper {
    uint256 private constant PRECISION = 1e18;

    /**
     * @notice Calculates the integer square root of a number.
     * @dev Uses the Babylonian method for approximation.
     * @param x The number to find the square root of.
     * @return y The integer square root of x.
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /**
     * @notice Calculates the collateral value of a given amount of LP tokens.
     * @dev The value is derived from the constant product `k` of the AMM's reserves.
     * The total value of the pool is considered to be sqrt(k).
     * @param reserveYes The total reserve of Yes tokens in the AMM.
     * @param reserveNo The total reserve of No tokens in the AMM.
     * @param totalSupply The total supply of LP tokens.
     * @param lpAmount The amount of LP tokens to value.
     * @return The value of the LP tokens in terms of collateral.
     */
    function getLpShareValue(
        uint256 reserveYes,
        uint256 reserveNo,
        uint256 totalSupply,
        uint256 lpAmount
    ) internal pure returns (uint256) {
        if (totalSupply == 0) {
            return 0;
        }
        uint256 k = reserveYes * reserveNo;
        uint256 totalValue = sqrt(k);
        return (lpAmount * totalValue) / totalSupply;
    }
}
