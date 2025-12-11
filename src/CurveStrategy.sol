// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "src/interfaces/ICurvePool.sol";

import "forge-std/console2.sol";

contract CurveStrategy is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    ICurvePool public immutable curvePool;
    IERC20 public immutable lpToken;
    address public vault;

    int128 public tokenIndex; // Index of our token in the pool

    event Deposited(uint256 amount, uint256 lpTokens);
    event Withdrawn(uint256 lpTokens, uint256 amount);
    event Harvested(uint256 profit);
    event VaultSet(address indexed vault);

    error CurveStrategy_OnlyVault();
    error CurveStrategy_ZeroAmount();
    error CurveStrategy_SlippageTooHigh();
    error CurveStrategy_VaultAlreadySet();
    error CurveStrategy_ZeroAddress();

    modifier onlyVault() {
        if (msg.sender != vault) revert CurveStrategy_OnlyVault();
        _;
    }

    constructor(IERC20 _asset, ICurvePool _curvePool, IERC20 _lpToken, int128 _tokenIndex) Ownable(msg.sender) {
        asset = _asset;
        curvePool = _curvePool;
        lpToken = _lpToken;
        tokenIndex = _tokenIndex;

        // Approve Curve pool
        _asset.forceApprove(address(_curvePool), type(uint256).max);
    }

    function setVault(address _vault) external onlyOwner {
        if (vault != address(0)) revert CurveStrategy_VaultAlreadySet();
        if (_vault == address(0)) revert CurveStrategy_ZeroAddress();
        vault = _vault;
        emit VaultSet(_vault);
    }

    function deposit(uint256 amount) external onlyVault {
        if (amount == 0) revert CurveStrategy_ZeroAmount();

        asset.safeTransferFrom(vault, address(this), amount);

        // Calculate minimum LP tokens with 0.5% slippage
        uint256 expectedLpTokens = curvePool.calc_token_amount([amount, 0], true);
        uint256 minLpTokens = (expectedLpTokens * 9950) / 10000;

        // Add liquidity (for 2-token pool)
        uint256 lpReceived = curvePool.add_liquidity([amount, 0], minLpTokens);
        console2.log("lpReceived = ", lpReceived);

        emit Deposited(amount, lpReceived);
    }

    // In CurveStrategy.sol
    function withdraw(uint256 amount) external onlyVault {
        if (amount == 0) revert CurveStrategy_ZeroAmount();

        uint256 lpBalance = lpToken.balanceOf(address(this));
        if (lpBalance == 0) return;

        uint256 totalAssets = curvePool.balances(uint256(uint128(tokenIndex)));
        uint256 totalSupply = lpToken.totalSupply();

        // Calculate our total balance in underlying
        uint256 ourTotalBalance = (lpBalance * totalAssets) / totalSupply;

        uint256 lpToWithdraw = (amount * totalSupply) / totalAssets;

        //If withdrawing > 99.9% of our position, just withdraw everything
        if (amount >= (ourTotalBalance * 999) / 1000) {
            lpToWithdraw = lpBalance; // Withdraw all LP tokens
            console2.log("Withdrawing entire LP position");
        } else if (lpToWithdraw > lpBalance) {
            lpToWithdraw = lpBalance;
        }

        // Adjust slippage based on withdrawal size
        uint256 minReceived;
        if (lpToWithdraw == lpBalance) {
            // Full withdrawal - accept whatever we get
            minReceived = 0;
        } else if (amount < 1e6) {
            // Small amounts - 5% slippage
            minReceived = (amount * 9500) / 10000;
        } else {
            // Normal - 0.5% slippage
            minReceived = (amount * 9950) / 10000;
        }

        console2.log("Curve withdraw:");
        console2.log("  Amount requested:", amount);
        console2.log("  Our total balance:", ourTotalBalance);
        console2.log("  LP balance:", lpBalance);
        console2.log("  LP to withdraw:", lpToWithdraw);
        console2.log("  Min received:", minReceived);

        uint256 received = curvePool.remove_liquidity_one_coin(lpToWithdraw, tokenIndex, minReceived);

        asset.safeTransfer(vault, received);

        emit Withdrawn(lpToWithdraw, received);
    }

    function harvest() external onlyVault {
        // Curve fees are automatically included in LP token value
        // No explicit harvest needed, but we emit event for tracking
        emit Harvested(0);
    }

    /**
     * @notice Get total balance in underlying asset terms
     */
    function balanceOf(address account) external view returns (uint256) {
        if (account != vault) return 0;

        uint256 lpBalance = lpToken.balanceOf(address(this));
        if (lpBalance == 0) return 0;

        // Calculate underlying asset value of LP tokens
        uint256 totalAssets = curvePool.balances(uint256(uint128(tokenIndex)));
        uint256 totalSupply = lpToken.totalSupply();

        return (lpBalance * totalAssets) / totalSupply;
    }

    function emergencyWithdraw() external onlyOwner {
        uint256 lpBalance = lpToken.balanceOf(address(this));
        if (lpBalance > 0) {
            uint256 minReceived = 0; // Accept any amount in emergency
            curvePool.remove_liquidity_one_coin(lpBalance, tokenIndex, minReceived);

            uint256 assetBalance = asset.balanceOf(address(this));
            asset.safeTransfer(owner(), assetBalance);
        }
    }
}
