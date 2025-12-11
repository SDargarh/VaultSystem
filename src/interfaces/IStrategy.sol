// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStrategy {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function harvest() external;
    function balanceOf(address account) external view returns (uint256);
}
