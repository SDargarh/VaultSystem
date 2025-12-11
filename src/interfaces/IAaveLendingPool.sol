// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAaveLendingPool
 * @notice Simplified Aave V3 interface
 */
interface IAaveLendingPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}
