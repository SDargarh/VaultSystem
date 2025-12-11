// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "src/interfaces/IAaveLendingPool.sol";

import "forge-std/console2.sol";


contract AaveStrategy is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    IAaveLendingPool public immutable aavePool;
    IERC20 public immutable aToken; // Interest-bearing token from Aave
    address public vault;

    event Deposited(uint256 amount);
    event VaultSet(address indexed vault);

    error AaveStrategy_OnlyVault();
    error AaveStrategy_ZeroAmount();
    error AaveStrategy_VaultAlreadySet();
    error AaveStrategy_ZeroAddress();

    modifier onlyVault() {
        if (msg.sender != vault) revert AaveStrategy_OnlyVault();
        _;
    }

    constructor(IERC20 _asset, IAaveLendingPool _aavePool, IERC20 _aToken) Ownable(msg.sender) {
        asset = _asset;
        aavePool = _aavePool;
        aToken = _aToken;

        // Approve Aave pool
        asset.forceApprove(address(aavePool), type(uint256).max);
    }

    function setVault(address _vault) external onlyOwner {
        if (vault != address(0)) revert AaveStrategy_VaultAlreadySet();
        if (_vault == address(0)) revert AaveStrategy_ZeroAddress();
        vault = _vault;
        emit VaultSet(_vault);
    }

    function deposit(uint256 amount) external onlyVault {
        if (amount == 0) revert AaveStrategy_ZeroAmount();

        asset.safeTransferFrom(vault, address(this), amount);
        aavePool.supply(address(asset), amount, address(this), 0);

        console2.log("amount deposited in Aave pool = ", amount);

        emit Deposited(amount);
    }

    /**
     * @notice Get total balance including accrued interest
     */
    function balanceOf(address account) external view returns (uint256) {
        if (account != vault) return 0;
        return aToken.balanceOf(address(this));
    }

}
