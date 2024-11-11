// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "@ds-math/math.sol";
import "../src/Start.sol";

contract CounterTest is Test, DSMath {
    MockPriceOracle public priceOracle;
    Stable public stable;

    address user1 = address(0x1);

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
        priceOracle = new MockPriceOracle();
        priceOracle.setPrice(3000e18);
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
}
