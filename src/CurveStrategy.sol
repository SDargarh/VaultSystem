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

    constructor(
        IERC20 _asset,
        ICurvePool _curvePool,
        IERC20 _lpToken,
        int128 _tokenIndex
    ) Ownable(msg.sender) {
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

    function balanceOf(address account) external view returns (uint256) {
        if (account != vault) return 0;

        uint256 lpBalance = lpToken.balanceOf(address(this));
        if (lpBalance == 0) return 0;

        // Calculate underlying asset value of LP tokens
        uint256 totalAssets = curvePool.balances(uint256(uint128(tokenIndex)));
        uint256 totalSupply = lpToken.totalSupply();

        return (lpBalance * totalAssets) / totalSupply;
    }


}
