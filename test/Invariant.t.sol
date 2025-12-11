// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MainVault} from "src/MainVault.sol";
import {AaveStrategy} from "src/AaveStrategy.sol";
import {CurveStrategy} from "src/CurveStrategy.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {MockAavePool} from "src/mocks/MockAavePool.sol";
import {MockCurvePool} from "src/mocks/MockCurvePool.sol";
import "src/interfaces/IStrategy.sol";


contract InvariantTests is Test {
    MainVault public vault;
    Handler public handler;
    
    MockERC20 public usdc;
    
    function setUp() public {
        // Deploy system
        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        
        MockAavePool aavePool = new MockAavePool(usdc);
        MockCurvePool curvePool = new MockCurvePool(usdc, dai);
        
        AaveStrategy aaveStrategy = new AaveStrategy(
            usdc,
            aavePool,
            aavePool.aToken()
        );
        
        CurveStrategy curveStrategy = new CurveStrategy(
            usdc,
            curvePool,
            curvePool.lpToken(),
            0
        );
        
        vault = new MainVault(
            usdc,
            "Modular Vault",
            "mvUSDC",
            IStrategy(address(aaveStrategy)),
            IStrategy(address(curveStrategy)),
            address(0x123)
        );
        
        aaveStrategy.transferOwnership(address(vault));
        curveStrategy.transferOwnership(address(vault));
        
        // Setup initial Curve liquidity
        dai.mint(address(this), 1_000_000e18);
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(curvePool), type(uint256).max);
        dai.approve(address(curvePool), type(uint256).max);
        curvePool.add_liquidity([uint256(500000e6), uint256(500000e18)], 0);
        
        // Deploy handler
        handler = new Handler(vault, usdc);
        
        // Fund handler
        usdc.mint(address(handler), 10_000_000e6);
        
        // Target handler for invariant tests
        targetContract(address(handler));
        
        // Configure selectors
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = Handler.deposit.selector;
        selectors[1] = Handler.withdraw.selector;
        selectors[2] = Handler.warpTime.selector;
        
        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }

    function invariant_totalAssetsGESupply() public {
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        
        if (totalSupply == 0) return;
        
        uint256 assetsPerShare = vault.convertToAssets(1e18);
        uint256 expectedAssets = (totalSupply * assetsPerShare) / 1e18;
        
        assertGe(totalAssets, expectedAssets, "Invariant: totalAssets < expected for totalSupply");
    }
    

    function invariant_solvency() public {
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        
        if (totalSupply > 0) {
            // All shares should be redeemable
            uint256 redeemableAssets = vault.convertToAssets(totalSupply);
            assertGe(totalAssets, redeemableAssets, "Invariant: Insolvent");
        }
    }
    

    function invariant_sharePriceMonotonic() public {
        uint256 currentPrice = handler.ghost_maxSharePrice();
        
        if (vault.totalSupply() > 0) {
            uint256 currentSharePrice = vault.convertToAssets(1e18);
            
            // Allow for small decrease due to fees (1%)
            assertGe(currentSharePrice * 100, currentPrice * 99, "Share price decreased significantly");
        }
    }
    

    function invariant_sumOfBalances() public {
        uint256 sumBalances = handler.ghost_sumBalances();
        uint256 totalSupply = vault.totalSupply();
        
        assertEq(sumBalances, totalSupply, "Sum of balances != totalSupply");
    }
    

    function invariant_userBalanceLTSupply() public {
        address[] memory actors = handler.getActors();
        uint256 totalSupply = vault.totalSupply();
        
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 balance = vault.balanceOf(actors[i]);
            assertLe(balance, totalSupply, "User balance > totalSupply");
        }
    }
    

    function invariant_callSummary() public view {
        handler.callSummary();
    }
}


contract Handler is Test {
    MainVault public vault;
    MockERC20 public usdc;
    
    // Ghost variables for tracking
    uint256 public ghost_depositSum;
    uint256 public ghost_withdrawSum;
    uint256 public ghost_maxSharePrice;
    uint256 public ghost_sumBalances;
    
    // Call counters
    uint256 public calls_deposit;
    uint256 public calls_withdraw;
    
    // Track actors
    address[] public actors;
    mapping(address => bool) public isActor;
    
    modifier useActor(uint256 actorSeed) {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }
    
    constructor(MainVault _vault, MockERC20 _usdc) {
        vault = _vault;
        usdc = _usdc;
        
        // Create actors
        for (uint256 i = 0; i < 5; i++) {
            address actor = address(uint160(0x10000 + i));
            actors.push(actor);
            isActor[actor] = true;
            
            // Fund actors
            usdc.mint(actor, 1_000_000e6);
            
            vm.prank(actor);
            usdc.approve(address(vault), type(uint256).max);
        }
        
        ghost_maxSharePrice = 1e18;
    }
    
    function deposit(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        amount = bound(amount, 1e6, 100_000e6);
        
        if (usdc.balanceOf(msg.sender) < amount) return;
        
        uint256 shares = vault.deposit(amount, msg.sender);
        
        ghost_depositSum += amount;
        ghost_sumBalances += shares;
        calls_deposit++;
        
        _updateSharePrice();
    }
    
    function withdraw(uint256 actorSeed, uint256 sharePercent) public useActor(actorSeed) {
        sharePercent = bound(sharePercent, 1, 100);
        
        uint256 shares = vault.balanceOf(msg.sender);
        if (shares == 0) return;
        
        uint256 sharesToWithdraw = (shares * sharePercent) / 100;
        if (sharesToWithdraw == 0) sharesToWithdraw = 1;
        
        uint256 assets = vault.redeem(sharesToWithdraw, msg.sender, msg.sender);
        
        ghost_withdrawSum += assets;
        ghost_sumBalances -= sharesToWithdraw;
        calls_withdraw++;
        
        _updateSharePrice();
    }
    
    function warpTime(uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 1 hours, 30 days);
        vm.warp(block.timestamp + timeDelta);
    }
    
    function _updateSharePrice() internal {
        if (vault.totalSupply() > 0) {
            uint256 currentPrice = vault.convertToAssets(1e18);
            if (currentPrice > ghost_maxSharePrice) {
                ghost_maxSharePrice = currentPrice;
            }
        }
    }
    
    function callSummary() external view {
        console.log("------- Call Summary -------");
        console.log("Total deposits:", calls_deposit);
        console.log("Total withdrawals:", calls_withdraw);
        console.log("Deposit sum:", ghost_depositSum);
        console.log("Withdraw sum:", ghost_withdrawSum);
        console.log("Max share price:", ghost_maxSharePrice);
        console.log("---------------------------");
    }
    
    function getActors() external view returns (address[] memory) {
        return actors;
    }
}