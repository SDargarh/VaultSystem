// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "src/interfaces/IStrategy.sol";

import "forge-std/console2.sol";

contract MainVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants & Immutables ============

    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant HARVESTER_ROLE = keccak256("HARVESTER_ROLE");

    uint256 public immutable MAX_BPS = 10000;
    uint256 public immutable STRATEGY_COUNT = 2;

    // ============ State Variables ============

    IStrategy public strategyA;
    uint16 public strategyARatio; // Target allocation in BPS (0-10000)
    uint16 public managementFeeBps; // Annual management fee
    uint16 public performanceFeeBps; // Performance fee on profits
    uint16 public rebalanceThresholdBps; // Trigger rebalance if deviation exceeds this

    IStrategy public strategyB;
    uint16 public strategyBRatio; // Target allocation in BPS (0-10000)

    // Rewards address where performance and management fees are sent to
    address public treasury;
    uint256 public lastHarvestTimestamp; // Track last harvest for time-based fees
    uint256 public totalProfits; // Cumulative profits for reporting

    // ============ Error Codes ============

    error MainVault_zeroAddress();
    error MainVault_InvalidAssetAmount();
    error MainVault_ZeroSharesExpected();
    error MainVault_InvalidRatio();
    error MainVault_InvalidFee();
    error MainVault_InsufficientBalance();
    error MainVault_StrategyFailed();
    error MainVault_InvalidWithdrawAmount();

    // ============ Events ============
    
    event Rebalanced(uint256 strategyABalance, uint256 strategyBBalance);
    event AllocationUpdated(uint16 strategyARatio, uint16 strategyBRatio);
    event FeesUpdated(uint16 managementFee, uint16 performanceFee);

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        IStrategy _strategyA,
        IStrategy _strategyB,
        address _treasury
    ) ERC4626(_asset) ERC20(_name, _symbol) {
        if (address(_strategyA) == address(0) || address(_strategyB) == address(0) || _treasury == address(0)) {
            revert MainVault_zeroAddress();
        }

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(STRATEGIST_ROLE, msg.sender);
        _grantRole(HARVESTER_ROLE, msg.sender);

        strategyA = _strategyA;
        strategyB = _strategyB;
        treasury = _treasury;

        // Initial strategy ratios (e.g., 50% each)
        strategyARatio = 5000; // 50%
        strategyBRatio = 5000; // 50%

        managementFeeBps = 200; // 2% annual
        performanceFeeBps = 2000; // 20% on profits

        // Default 5% rebalance threshold
        rebalanceThresholdBps = 500;

        lastHarvestTimestamp = block.timestamp;

        IERC20(_asset).forceApprove(address(strategyA), type(uint256).max);
        IERC20(_asset).forceApprove(address(strategyB), type(uint256).max);
    }

    // ============ ERC4626 functionalities ============

    function totalAssets() public view override returns (uint256) {
        return _totalAssets();
    }

    function _totalAssets() internal view returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 stratABalance = strategyA.balanceOf(address(this));
        uint256 stratBBalance = strategyB.balanceOf(address(this));

        unchecked {
            return idle + stratABalance + stratBBalance;
        }
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) {
            revert MainVault_zeroAddress();
        }

        if (assets <= 0) {
            revert MainVault_InvalidAssetAmount();
        }

        uint256 expectedShares = super.previewDeposit(assets);
        if (expectedShares == 0) {
            revert MainVault_ZeroSharesExpected();
        }

        shares = super.deposit(assets, receiver);
        _deployCapital();
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        assets = super.mint(shares, receiver);
        _deployCapital();
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if(assets <= 0) revert MainVault_InvalidWithdrawAmount();
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) {
            _withdrawFromStrategies(assets - idle);
        }

        shares = super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        // Calculate assets needed
        assets = previewRedeem(shares);

        console2.log("Redeem: assets needed =", assets);

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        console2.log("Redeem: idle balance =", idle);

        if (assets > idle) {
            uint256 needed = assets - idle;

            //Add small buffer for rounding (2 units)
            uint256 toWithdraw = needed + 2;

            console2.log("Redeem: withdrawing from strategies =", toWithdraw);
            _withdrawFromStrategies(toWithdraw);
        }

        assets = super.redeem(shares, receiver, owner);
    }

    // ============ Strategy Management ============

    function rebalance() external onlyRole(STRATEGIST_ROLE) nonReentrant {
        uint256 total = _totalAssets();

        if (total == 0) return;

        uint256 stratABalance = strategyA.balanceOf(address(this));
        uint256 stratBBalance = strategyB.balanceOf(address(this));

        // Calculate target allocations
        uint256 targetA = (total * strategyARatio) / MAX_BPS;
        uint256 targetB = (total * strategyBRatio) / MAX_BPS;

        // Check if rebalance is needed (exceeds threshold)
        if (!_needsRebalance(stratABalance, stratBBalance, targetA, targetB)) {
            return;
        }

        // Withdraw everything to vault
        if (stratABalance > 0) {
            strategyA.withdraw(stratABalance);
        }
        if (stratBBalance > 0) {
            strategyB.withdraw(stratBBalance);
        }

        // Deploy to strategies with new allocation
        uint256 idle = IERC20(asset()).balanceOf(address(this));

        if (targetA > 0 && idle > 0) {
            uint256 amountA = targetA < idle ? targetA : idle;
            strategyA.deposit(amountA);
            idle -= amountA;
        }

        if (targetB > 0 && idle > 0) {
            uint256 amountB = targetB < idle ? targetB : idle;
            strategyB.deposit(amountB);
        }

        emit Rebalanced(strategyA.balanceOf(address(this)), strategyB.balanceOf(address(this)));
    }

    function _deployCapital() internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle == 0) return;

        uint256 toStrategyA = (idle * strategyARatio) / MAX_BPS;
        uint256 toStrategyB = (idle * strategyBRatio) / MAX_BPS;

        if (toStrategyA > 0) {
            strategyA.deposit(toStrategyA);
        }

        if (toStrategyB > 0) {
            strategyB.deposit(toStrategyB);
        }
    }

    function _withdrawFromStrategies(uint256 amount) internal {
        uint256 stratABalance = strategyA.balanceOf(address(this));
        uint256 stratBBalance = strategyB.balanceOf(address(this));
        uint256 totalDeployed = stratABalance + stratBBalance;

        if (totalDeployed == 0) revert MainVault_InsufficientBalance();

        // Withdraw proportionally
        if (stratABalance > 0) {
            uint256 withdrawA = (amount * stratABalance) / totalDeployed;
            withdrawA = withdrawA > stratABalance ? stratABalance : withdrawA;
            if (withdrawA > 0) {
                strategyA.withdraw(withdrawA);
            }
        }

        if (stratBBalance > 0) {
            uint256 withdrawB = (amount * stratBBalance) / totalDeployed;
            withdrawB = withdrawB > stratBBalance ? stratBBalance : withdrawB;
            if (withdrawB > 0) {
                strategyB.withdraw(withdrawB);
            }
        }

        // If still not enough, try to get remaining from other strategy
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < amount) {
            uint256 remaining = amount - idle;

            // Try strategy A first
            uint256 stratAAfter = strategyA.balanceOf(address(this));
            if (stratAAfter >= remaining) {
                strategyA.withdraw(remaining);
            } else if (stratAAfter > 0) {
                strategyA.withdraw(stratAAfter);
                remaining -= stratAAfter;

                // Then try strategy B
                uint256 stratBAfter = strategyB.balanceOf(address(this));
                if (stratBAfter >= remaining) {
                    strategyB.withdraw(remaining);
                } else if (stratBAfter > 0) {
                    strategyB.withdraw(stratBAfter);
                }
            }
        }
    }

    function _needsRebalance(uint256 currentA, uint256 currentB, uint256 targetA, uint256 targetB)
        internal
        view
        returns (bool)
    {
        if (targetA == 0 && targetB == 0) return false;

        // Calculate percentage deviation
        uint256 deviationA = currentA > targetA
            ? ((currentA - targetA) * MAX_BPS) / (targetA > 0 ? targetA : 1)
            : ((targetA - currentA) * MAX_BPS) / (targetA > 0 ? targetA : 1);

        uint256 deviationB = currentB > targetB
            ? ((currentB - targetB) * MAX_BPS) / (targetB > 0 ? targetB : 1)
            : ((targetB - currentB) * MAX_BPS) / (targetB > 0 ? targetB : 1);

        return deviationA > rebalanceThresholdBps || deviationB > rebalanceThresholdBps;
    }


    // ============ Admin Functions ============

    function setAllocation(uint16 _strategyARatio, uint16 _strategyBRatio) 
        external 
        onlyRole(STRATEGIST_ROLE) 
    {
        if (_strategyARatio + _strategyBRatio != MAX_BPS) revert MainVault_InvalidRatio();
        
        strategyARatio = _strategyARatio;
        strategyBRatio = _strategyBRatio;
        
        emit AllocationUpdated(_strategyARatio, _strategyBRatio);
    }

    function setFees(uint16 _managementFee, uint16 _performanceFee) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (_managementFee > 1000) revert MainVault_InvalidFee(); // Max 10%
        if (_performanceFee > 5000) revert MainVault_InvalidFee(); // Max 50%
        
        managementFeeBps = _managementFee;
        performanceFeeBps = _performanceFee;
        
        emit FeesUpdated(_managementFee, _performanceFee);
    }

    function setRebalanceThreshold(uint16 _threshold) 
        external 
        onlyRole(STRATEGIST_ROLE) 
    {
        if (_threshold > 5000) revert MainVault_InvalidFee(); // Max 50%
        rebalanceThresholdBps = _threshold;
    }


    // ============ View Functions ============

    function getStrategyBalances() external view returns (uint256, uint256) {
        return (
            strategyA.balanceOf(address(this)),
            strategyB.balanceOf(address(this))
        );
    }

    function needsRebalance() external view returns (bool) {
        uint256 total = _totalAssets();
        if (total == 0) return false;
        
        uint256 stratABalance = strategyA.balanceOf(address(this));
        uint256 stratBBalance = strategyB.balanceOf(address(this));
        uint256 targetA = (total * strategyARatio) / MAX_BPS;
        uint256 targetB = (total * strategyBRatio) / MAX_BPS;
        
        return _needsRebalance(stratABalance, stratBBalance, targetA, targetB);
    }
}
