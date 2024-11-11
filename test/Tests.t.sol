// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "@ds-math/math.sol";
import "../src/Stable.sol";

contract CounterTest is Test, DSMath {
    address user1 = address(0x1);
    address liquidator = address(0x2);
    address priceOracleOwner = address(0x3);
    address stableContractOwner = address(0x4);

    MockPriceOracle public priceOracle;
    Stable public stable;

    uint firstInterestRate_wad = 1.0000001e18;

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
        vm.startPrank(stableContractOwner);
        stable = new Stable(priceOracle, wadToRay(firstInterestRate_wad));
        vm.stopPrank();
        
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

    // function test_changingInterestScenario() public {
    //     // interest rate starts at 1.1

    //     // at t=100, user opens a position with 1ETH and takes a loan of 1000
    //     vm.warp(100);
    //     vm.startPrank(user1);
    //     stable.openPosition{value:1e18}();
    //     stable.takeLoan(1000e18);
    //     vm.stopPrank();

    //     // at t=200, interest rate changes to 1.2
    //     vm.warp(200);
    //     vm.startPrank(stableContractOwner);
    //     stable.updateInterestRate(wadToRay(1.0000001e18));
    //     vm.stopPrank();

    //     // at t=300, user repays 1000
    //     vm.warp(300);
    //     vm.startPrank(user1);
    //     stable.repayLoan(1000e18);
    //     vm.stopPrank();

    //     // due to interest, user should have more debt left over.
    //     // they should have accrued the first interest rate for 100 seconds, and the second interest rate for 100 seconds.
    //     // TODO: calculate this value and assert that's what comes out.
    // }
}
