// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "@ds-math/math.sol";
import "../src/Start.sol";

contract CounterTest is Test, DSMath {
    MockPriceOracle public priceOracle;
    Stable public stable;

    address user1 = address(0x1);
    address liquidator = address(0x2);
    address priceOracleOwner = address(0x3);

    uint firstInterestRate_wad = 1.000001e18;

    // Go from wad (10**18) to ray (10**27)
    function wadToRay(uint _wad) internal pure returns (uint) {
        return mul(_wad, 10 ** 9);
    }

    // Go from wei to ray (10**27)
    function weiToRay(uint _wei) internal pure returns (uint) {
        return mul(_wei, 10 ** 27);
    } 

    function setUp() public {
        vm.warp(0);
        vm.startPrank(priceOracleOwner);
        priceOracle = new MockPriceOracle();
        priceOracle.setPrice(3000e18);
        vm.stopPrank();
        stable = new Stable(priceOracle, wadToRay(firstInterestRate_wad));
        
        vm.deal(user1, 10e18);
    }

    function test_twoSecondInterestAccumulate() public {
        vm.startPrank(user1);
        stable.openPosition{value:1e18}();
        stable.takeLoan(1e18);
        vm.warp(2);
        assertEq(stable.getPositionDebtWithInterest(user1), wmul(wmul(1e18, firstInterestRate_wad), firstInterestRate_wad));
        vm.stopPrank();
    }

    function test_userCantTakeMoreThanMaxDebt() public {
        vm.startPrank(user1);
        stable.openPosition{value:1e18}();
        vm.expectRevert("Not enough collateral to take this loan");
        stable.takeLoan(3000e18);
        vm.stopPrank();
    }

    function test_liquidatePosition() public {
        vm.startPrank(user1);
        stable.openPosition{value:1e18}();
        stable.takeLoan(1900e18);

        // send the loaned amount to liquidator so he can repay the loan
        stable.transfer(liquidator, 1900e18);
        vm.stopPrank();

        // change the pric to 1500
        vm.startPrank(priceOracleOwner);
        priceOracle.setPrice(1500e18);
        vm.stopPrank();

        vm.startPrank(liquidator);
        stable.liquidatePosition(user1);
        vm.stopPrank();

        // user1 should have no debt and no collateral
        assertEq(stable.getPositionDebtWithInterest(user1), 0);
        assertEq(stable.getPositionCollateral(user1), 0);

        // liquidator should have the collateral in eth
        assertEq(address(liquidator).balance, 1e18);
    }

    // schalk scenario
}
