// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "src/mocks/MockAToken.sol";
import "src/mocks/MockERC20.sol";
import "src/interfaces/IAaveLendingPool.sol";

import "forge-std/console2.sol";

contract MockAavePool is IAaveLendingPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    MockAToken public immutable aToken;

    uint256 public apy = 500; // 5%
    uint256 public constant YEAR = 365 days;
    uint256 public constant BPS = 10000;

    uint256 public lastUpdateTime;
    
    // Track the exchange rate (scaled by 1e18)
    uint256 public exchangeRate = 1e18; // Start at 1:1

    constructor(IERC20 _asset) {
        asset = _asset;
        aToken = new MockAToken("Aave USDC", "aUSDC", address(_asset));
        lastUpdateTime = block.timestamp;
    }

    function supply(address _asset, uint256 amount, address onBehalfOf, uint16) external {
        require(_asset == address(asset), "Invalid asset");

        _accrueInterest();

        // Transfer USDC from user
        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        // Mint aTokens based on CURRENT exchange rate
        // If 1 aToken = 1.05 USDC, then 100 USDC = 95.24 aTokens
        uint256 aTokensToMint = (amount * 1e18) / exchangeRate;
        aToken.mint(onBehalfOf, aTokensToMint);
        
        console2.log("Supplied:", amount);
        console2.log("Exchange rate:", exchangeRate);
        console2.log("aTokens minted:", aTokensToMint);
    }

    function withdraw(address _asset, uint256 amount, address to) external returns (uint256) {
        require(_asset == address(asset), "Invalid asset");

        _accrueInterest();

        // Convert USDC amount to aToken amount using exchange rate
        uint256 aTokensNeeded = (amount * 1e18) / exchangeRate;
        uint256 aTokenBalance = aToken.balanceOf(msg.sender);
        
        uint256 aTokensToBurn = aTokensNeeded > aTokenBalance ? aTokenBalance : aTokensNeeded;
        
        // Convert aTokens back to USDC amount
        uint256 usdcToWithdraw = (aTokensToBurn * exchangeRate) / 1e18;

        console2.log("Withdraw requested:", amount);
        console2.log("aToken balance:", aTokenBalance);
        console2.log("aTokens to burn:", aTokensToBurn);
        console2.log("USDC to withdraw:", usdcToWithdraw);
        console2.log("Exchange rate:", exchangeRate);

        aToken.burn(msg.sender, aTokensToBurn);
        asset.safeTransfer(to, usdcToWithdraw);

        return usdcToWithdraw;
    }

    function _accrueInterest() internal {
        if (block.timestamp == lastUpdateTime) {
            return;
        }

        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        
        // Calculate interest rate increase
        // exchangeRate increases by APY over time
        uint256 rateIncrease = (exchangeRate * apy * timeElapsed) / (BPS * YEAR);
        
        console2.log("=== Interest Accrual ===");
        console2.log("Time elapsed (seconds):", timeElapsed);
        console2.log("Old exchange rate:", exchangeRate);
        console2.log("Rate increase:", rateIncrease);
        
        if (rateIncrease > 0) {
            exchangeRate += rateIncrease;
            
            // Mint USDC to pool to back the increased value
            uint256 totalValueBefore = (aToken.totalSupply() * (exchangeRate - rateIncrease)) / 1e18;
            uint256 totalValueAfter = (aToken.totalSupply() * exchangeRate) / 1e18;
            uint256 interestToMint = totalValueAfter - totalValueBefore;
            
            if (interestToMint > 0) {
                MockERC20(address(asset)).mint(address(this), interestToMint);
            }
            
            console2.log("New exchange rate:", exchangeRate);
            console2.log("Interest minted:", interestToMint);
        }

        lastUpdateTime = block.timestamp;
    }

    function accrueInterest() external {
        _accrueInterest();
    }

    function setAPY(uint256 _apy) external {
        _accrueInterest();
        apy = _apy;
    }
    
    // Helper to get underlying balance for an aToken amount
    function getUnderlyingBalance(address account) external view returns (uint256) {
        uint256 aTokenBalance = aToken.balanceOf(account);
        return (aTokenBalance * exchangeRate) / 1e18;
    }
}