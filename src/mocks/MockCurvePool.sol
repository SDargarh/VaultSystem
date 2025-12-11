// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "src/mocks/MockCurveLP.sol";
import "src/mocks/MockERC20.sol";
import "src/interfaces/ICurvePool.sol";

/**
 * @title MockCurvePool
 * @notice Mock Curve AMM pool with simulated fees
 */
contract MockCurvePool is ICurvePool {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    MockCurveLP public immutable lpToken;

    uint256 public balance0;
    uint256 public balance1;

    // Trading fee: 4 basis points (0.04%)
    uint256 public fee = 4;
    uint256 public constant FEE_DENOMINATOR = 10000;

    // Accumulated fees for yield simulation
    uint256 public accumulatedFees0;
    uint256 public accumulatedFees1;

    constructor(IERC20 _token0, IERC20 _token1) {
        token0 = _token0;
        token1 = _token1;
        lpToken = new MockCurveLP("Curve LP Token", "crvLP");
    }

    /**
     * @notice Add liquidity to the pool
     */
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external returns (uint256) {
        uint256 lpAmount;

        if (lpToken.totalSupply() == 0) {
            // Initial liquidity
            lpAmount = amounts[0] + amounts[1];
        } else {
            // Calculate LP tokens proportional to pool
            uint256 total = balance0 + balance1;
            lpAmount = ((amounts[0] + amounts[1]) * lpToken.totalSupply()) / total;
        }

        require(lpAmount >= min_mint_amount, "Slippage");

        if (amounts[0] > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amounts[0]);
            balance0 += amounts[0];
        }

        if (amounts[1] > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amounts[1]);
            balance1 += amounts[1];
        }

        lpToken.mint(msg.sender, lpAmount);

        return lpAmount;
    }

    /**
     * @notice Remove liquidity in a single token
     */
    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external returns (uint256) {
        require(i == 0 || i == 1, "Invalid index");

        uint256 totalSupply = lpToken.totalSupply();
        require(totalSupply > 0, "No liquidity");

        // Calculate share of pool
        uint256 share = (token_amount * FEE_DENOMINATOR) / totalSupply;

        uint256 amount;
        if (i == 0) {
            amount = (balance0 * share) / FEE_DENOMINATOR;
            require(amount >= min_amount, "Slippage");
            balance0 -= amount;
            token0.safeTransfer(msg.sender, amount);
        } else {
            amount = (balance1 * share) / FEE_DENOMINATOR;
            require(amount >= min_amount, "Slippage");
            balance1 -= amount;
            token1.safeTransfer(msg.sender, amount);
        }

        lpToken.burn(msg.sender, token_amount);

        return amount;
    }

    /**
     * @notice Calculate LP tokens for given amounts
     */
    function calc_token_amount(
        uint256[2] calldata amounts,
        bool /* is_deposit */
    )
        external
        view
        returns (uint256)
    {
        if (lpToken.totalSupply() == 0) {
            return amounts[0] + amounts[1];
        }

        uint256 total = balance0 + balance1;
        return ((amounts[0] + amounts[1]) * lpToken.totalSupply()) / total;
    }

    /**
     * @notice Get balance of token at index
     */
    function balances(uint256 i) external view returns (uint256) {
        if (i == 0) return balance0;
        if (i == 1) return balance1;
        revert("Invalid index");
    }

    /**
     * @notice Simulate trading fees (for testing yield)
     */
    function simulateTrading(uint256 volume) external {
        uint256 fees = (volume * fee) / FEE_DENOMINATOR;

        // Add fees to pool balances (simulates trading yield)
        MockERC20(address(token0)).mint(address(this), fees / 2);
        MockERC20(address(token1)).mint(address(this), fees / 2);

        balance0 += fees / 2;
        balance1 += fees / 2;

        accumulatedFees0 += fees / 2;
        accumulatedFees1 += fees / 2;
    }

    /**
     * @notice Set fee rate (for testing)
     */
    function setFee(uint256 _fee) external {
        fee = _fee;
    }
}
