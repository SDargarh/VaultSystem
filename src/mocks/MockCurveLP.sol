// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockCurveLP
 * @notice Mock Curve LP token
 */
contract MockCurveLP is ERC20 {
    address public immutable pool;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        pool = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == pool, "Only pool");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == pool, "Only pool");
        _burn(from, amount);
    }
}
