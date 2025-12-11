// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "src/MainVault.sol";
import "src/AaveStrategy.sol";
import "src/CurveStrategy.sol";
import "src/mocks/MockERC20.sol";
import "src/mocks/MockAToken.sol";
import "src/mocks/MockAavePool.sol";
import "src/mocks/MockCurvePool.sol";
import "src/interfaces/IStrategy.sol";

import {console2} from "forge-std/console2.sol";

contract MainVaultTest is Test {
    MainVault public vault;
    AaveStrategy public aaveStrategy;
    CurveStrategy public curveStrategy;

    MockERC20 public usdc;
    MockERC20 public dai;
    // MockAToken public aToken;
    MockAavePool public aavePool;
    MockCurvePool public curvePool;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public treasury = address(0x3);
    address public strategist = address(0x4);

    uint256 constant INITIAL_BALANCE = 1000000e6; // 1M USDC
    uint256 constant DEPOSIT_AMOUNT = 100_000e6; // 100k USDC

    event Harvested(uint256 profit, uint256 fees);
    event Rebalanced(uint256 strategyABalance, uint256 strategyBBalance);

    function setUp() public {
        //Deploy Token
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("DAI stablecoin", "DAI", 18);

        //Deploy Protocol
        aavePool = new MockAavePool(usdc);
        curvePool = new MockCurvePool(usdc, dai);

        //Deploy 1st Aave Strategy
        aaveStrategy = new AaveStrategy(usdc, aavePool, IERC20(address(aavePool.aToken())));
        curveStrategy = new CurveStrategy(usdc, curvePool, IERC20(address(curvePool.lpToken())), 0);

        //Deploy Vault with strategy addresses
        vault = new MainVault(usdc, "Main USDC Vault", "mvUSDC", IStrategy(address(aaveStrategy)), IStrategy(address(curveStrategy)), treasury);
        console2.log("Vault deployed at:", address(vault));

        aaveStrategy.setVault(address(vault));
        curveStrategy.setVault(address(vault));

        //setup user with USDC
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_nothing() public {
        console2.log("Test setup complete");
    }

    function test_deposit() public {
        vm.startPrank(alice);

        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        console2.log("Alice deposited:", DEPOSIT_AMOUNT);
        console2.log("Shares minted:", shares);
        console2.log("Alice's vault balance:", vault.balanceOf(alice));
        console2.log("Vault total assets:", vault.totalAssets());

        assertEq(vault.balanceOf(alice), shares, "Incorrect shares");
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT, "Incorrect total assets");
        assertGt(shares, 0, "No shares minted");
    }

    function testMultipleDeposits() public {
        // Alice deposits
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(DEPOSIT_AMOUNT, alice);
        
        // Bob deposits same amount
        vm.prank(bob);
        uint256 bobShares = vault.deposit(DEPOSIT_AMOUNT, bob);
        
        // Shares should be equal for equal deposits
        assertEq(aliceShares, bobShares, "Unequal shares for equal deposits");
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT * 2, "Incorrect total");
    }

    function testWithdraw() public {
        vm.startPrank(alice);
        
        vault.deposit(DEPOSIT_AMOUNT, alice);
        
        uint256 balanceBefore = usdc.balanceOf(alice);
        vault.withdraw(DEPOSIT_AMOUNT / 2, alice, alice);
        uint256 balanceAfter = usdc.balanceOf(alice);
        
        assertEq(balanceAfter - balanceBefore, DEPOSIT_AMOUNT / 2, "Incorrect withdrawal");
        
        vm.stopPrank();
    }

    function testRedeem() public {
        vm.startPrank(alice);
        
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        
        uint256 balanceBefore = usdc.balanceOf(alice);
        uint256 assets = vault.redeem(shares / 2, alice, alice);
        uint256 balanceAfter = usdc.balanceOf(alice);
        
        assertEq(balanceAfter - balanceBefore, assets, "Assets mismatch");
        assertEq(vault.balanceOf(alice), shares / 2, "Shares not burned");
        
        vm.stopPrank();
    }

    function test_FullWithdrawal() public {
        vm.startPrank(alice);
        
        vault.deposit(DEPOSIT_AMOUNT, alice); // 100k
        
        vm.warp(block.timestamp + 10 days);
        
        // This should trigger interest accrual
        aavePool.accrueInterest();
        
        uint256 shares = vault.balanceOf(alice);
        uint256 balanceBefore = usdc.balanceOf(alice);
        
        console2.log("Before withdrawal:");
        console2.log("  Total assets:", vault.totalAssets());
        console2.log("  Expected:", vault.previewRedeem(shares));
        
        vault.redeem(shares, alice, alice);
        
        uint256 balanceAfter = usdc.balanceOf(alice);
        console2.log("Withdrawn:", balanceAfter - balanceBefore);
        
        // Should be > 100k now!
        assertGt(balanceAfter - balanceBefore, DEPOSIT_AMOUNT);
        
        vm.stopPrank();
    }
}
