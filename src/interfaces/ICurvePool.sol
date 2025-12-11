// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICurvePool
 * @notice Simplified Curve pool interface (2-token pool)
 */
interface ICurvePool {
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external returns (uint256);

    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external returns (uint256);

    function calc_token_amount(uint256[2] calldata amounts, bool is_deposit) external view returns (uint256);

    function balances(uint256 i) external view returns (uint256);
}
