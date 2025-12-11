// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "src/mocks/MockAToken.sol";
import "src/mocks/MockERC20.sol";
import "src/interfaces/IAaveLendingPool.sol";

contract MockAavePool is IAaveLendingPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    MockAToken public immutable aToken;

    // Simulated APY: 500 = 5%
    uint256 public apy = 500;
    uint256 public constant YEAR = 365 days;
    uint256 public constant BPS = 10000;

    uint256 public lastUpdateTime;

    constructor(IERC20 _asset) {
        asset = _asset;
        aToken = new MockAToken("Aave USDC", "aUSDC", address(_asset));
        lastUpdateTime = block.timestamp;
    }

    /**
     * @notice Supply assets and receive aTokens
     */
    function supply(
        address _asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /* referralCode */
    )
        external
    {
        require(_asset == address(asset), "Invalid asset");

        // Accrue interest before new supply
        _accrueInterest();

        asset.safeTransferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    /**
     * @notice Withdraw assets by burning aTokens
     */
    function withdraw(address _asset, uint256 amount, address to) external returns (uint256) {
        require(_asset == address(asset), "Invalid asset");

        // Accrue interest before withdrawal
        _accrueInterest();

        uint256 aTokenBalance = aToken.balanceOf(msg.sender);
        uint256 toWithdraw = amount > aTokenBalance ? aTokenBalance : amount;

        aToken.burn(msg.sender, toWithdraw);
        asset.safeTransfer(to, toWithdraw);

        return toWithdraw;
    }

    /**
     * @notice Simulate interest accrual
     */
    function _accrueInterest() internal {
        if (block.timestamp == lastUpdateTime) return;

        uint256 totalSupply = aToken.totalSupply();
        if (totalSupply == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        uint256 interest = (totalSupply * apy * timeElapsed) / (BPS * YEAR);

        if (interest > 0) {
            // Mint interest to the pool's aToken holders proportionally
            // This simulates yield accrual
            MockERC20(address(asset)).mint(address(this), interest);
        }

        lastUpdateTime = block.timestamp;
    }

    /**
     * @notice Manually accrue interest (for testing)
     */
    function accrueInterest() external {
        _accrueInterest();
    }

    /**
     * @notice Set APY for testing
     */
    function setAPY(uint256 _apy) external {
        _accrueInterest();
        apy = _apy;
    }
}
