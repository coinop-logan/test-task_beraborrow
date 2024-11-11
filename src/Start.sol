// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/token/ERC20/ERC20.sol";
import "@openzeppelin/access/Ownable.sol";
import "@ds-math/math.sol";

import {console} from "forge-std/console.sol";

/*
    MockPriceOracle is a simple price oracle that returns a constant price for ETH.
    Obviously not suitable for production.
*/

contract MockPriceOracle {
    address public owner;

    uint public ethPrice;

    modifier onlyOwner() {
        require(msg.sender == owner, "msg.sender is not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setPrice(uint _ethPrice) external onlyOwner {
        ethPrice = _ethPrice;
    }
}

/*
    Stable is a simple stablecoin protocol.
    Interest is accrued per second. The interest rate can be changed by the owner at any time.
    A global interest index is used to calculate the accrued debt on a position at a given time.

    Liquidators can liquidate undercollateralized positions.
    They are incentivized to do so for any position that has a collateral ratio above 1.0x.
    Thus this protocol becomes unstable and likely insolvent if the price of ETH falls so quickly
    that positions begin to fall below 1.0x collateral ratio before liquidators catch on.
    Gas costs of liquidators make this even worse.
    I am considering this issue out of scope, but some ideas:
    - Adjust POSITION_LIQUIDATE_LTV to be higher.
    - Remove/lower barriers to entry to liquidators, i.e. build good dashboards etc.
    - A minimum position size could be enforced to mitigate gas cost concerns for liquidators.
*/
contract Stable is ERC20, Ownable, DSMath {
    MockPriceOracle priceOracle;

    // A user can take debt as long as the collateral is valued at this ratio of the debt or above
    uint constant POSITION_TAKELOAN_LTV = 1.5e18; // 1.5
    // A liquidator can liquidate a position if the collateral is valued at this ratio of the debt or below
    uint constant POSITION_LIQUIDATE_LTV = 1.1e18; // 1.1

    uint public interestRatePerSecond_ray;
    // The global interest index, which is used to calculate the interest accrued on a position
    uint public globalInterestIndex_wad;
    // The timestamp of the last interest rate change
    uint public lastInterestChangeTimestamp;

    struct Position {
        uint collateral;
        uint debt;
        // The interest index at the last update, used to calculate the interest accrued on a position at a given time
        uint interestIndexAtLastUpdate_wad;
    }

    mapping(address => Position) userPositions;

    event PositionOpened(address indexed user, uint amount);
    event PositionBorrowed(address indexed user, uint amount);
    event PositionRepaid(address indexed user, uint amount);
    event PositionClosed(address indexed user);
    event PositionLiquidated(address indexed user);
    event InterestRateUpdated(uint newRate);
    
    constructor(MockPriceOracle _priceOracle, uint _interestRatePerSecond_ray)
        ERC20("Stable", "STBL")
        Ownable(msg.sender)
    {
        priceOracle = _priceOracle;

        interestRatePerSecond_ray = _interestRatePerSecond_ray;
        globalInterestIndex_wad = 1e18; // starts at 1
        lastInterestChangeTimestamp = block.timestamp;
    }

    // --- OWNER FUNCTIONS ---

    function updateInterestRate(uint _interestRatePerSecond_ray) external onlyOwner {
        accrueGlobalInterest();

        interestRatePerSecond_ray = _interestRatePerSecond_ray;
        emit InterestRateUpdated(_interestRatePerSecond_ray);
    }

    // --- POSITION HOLDER FUNCTIONS ---

    function openPosition() external payable {
        require(msg.value > 0, "Deposit must be greater than 0");

        Position storage userPosition = userPositions[msg.sender];

        require(userPosition.collateral == 0, "User already has position open");

        userPosition.collateral = msg.value;
        console.log("userPosition.collateral", userPosition.collateral);
        userPosition.interestIndexAtLastUpdate_wad = calcCurrentGlobalInterestIndex_wad();

        emit PositionOpened(msg.sender, msg.value);
    }

    function takeLoan(uint loanAmount) external {
        require(loanAmount > 0, "Loan amount must be greater than 0");

        accrueUserInterest(msg.sender);

        Position storage userPosition = userPositions[msg.sender];

        uint requiredCollateral_debtDenominated = wmul((userPosition.debt + loanAmount), POSITION_TAKELOAN_LTV);
        uint requiredCollateral = wdiv(requiredCollateral_debtDenominated, priceOracle.ethPrice());

        require(userPosition.collateral >= requiredCollateral, "Not enough collateral to take this loan");

        userPosition.debt += loanAmount;

        _mint(msg.sender, loanAmount);
        emit PositionBorrowed(msg.sender, loanAmount);
    }

    function repayLoan(uint repayAmount) public {
        require(repayAmount > 0, "Repay amount must be greater than 0");

        accrueUserInterest(msg.sender);
        // todo: should this be here, or in _repayLoan()?
        // just putting it up there naively would result in the next line not having the right debt value, preventing the user from ever paying back all debt.

        require(userPositions[msg.sender].debt >= repayAmount, "Repay amount must be equal to or less than debt");

        _repayLoanFromMsgSender(msg.sender, repayAmount);
    }

    function closePosition() external {
        Position storage userPosition = userPositions[msg.sender];

        require(userPosition.collateral > 0, "User does not have a position open");

        accrueUserInterest(msg.sender);

        // Repay loan if necessary
        _repayLoanFromMsgSender(msg.sender, userPosition.debt);

        uint collateralToReturn = userPosition.collateral;
        userPosition.collateral = 0;
        payable(msg.sender).transfer(collateralToReturn); // todo: better method?

        emit PositionClosed(msg.sender);
    }

    // --- LIQUIDATOR FUNCTIONS ---

    function liquidatePosition(address user) external {
        Position storage userPosition = userPositions[user];

        require(userPosition.collateral > 0, "User does not have a position open");

        accrueUserInterest(user);

        uint requiredCollateral_debtDenominated = wmul(userPosition.debt, POSITION_LIQUIDATE_LTV);
        uint requiredCollateral = wdiv(requiredCollateral_debtDenominated, priceOracle.ethPrice());

        require(userPosition.collateral < requiredCollateral, "User is not undercollateralized");

        _repayLoanFromMsgSender(user, userPosition.debt);

        payable(msg.sender).transfer(userPosition.collateral); // todo: better method?
        userPosition.collateral = 0;

        emit PositionLiquidated(user);
    }

    // --- INTERNAL FUNCTIONS ---

    function accrueGlobalInterest() internal {
        uint secondsElapsed = block.timestamp - lastInterestChangeTimestamp;

        if (secondsElapsed > 0) {
            globalInterestIndex_wad = calcCurrentGlobalInterestIndex_wad();

            lastInterestChangeTimestamp = block.timestamp;
        }
    }

    function accrueUserInterest(address user) internal {
        userPositions[user].debt = getPositionDebtWithInterest(user);
        userPositions[user].interestIndexAtLastUpdate_wad = calcCurrentGlobalInterestIndex_wad();
        // todo: the above results in two calls to calcCurrentGlobalInterestIndex_wad; code should be reorganized to avoid this.
    }

    function _repayLoanFromMsgSender(address who, uint repayAmount) internal {
        userPositions[who].debt -= repayAmount;
        _burn(msg.sender, repayAmount);
        emit PositionRepaid(who, repayAmount);
    }

    // --- PURE/VIEW FUNCTIONS ---

    function calcCurrentGlobalInterestIndex_wad() internal view returns (uint) {
        uint secondsElapsed = block.timestamp - lastInterestChangeTimestamp;

        return accrueInterest_wad(globalInterestIndex_wad, interestRatePerSecond_ray, secondsElapsed);
    }

    function getPositionDebtWithInterest(address user) public view returns (uint) {
        Position storage userPosition = userPositions[user];

        if (userPosition.debt == 0) {
            return 0;
        }

        return userPosition.debt * calcCurrentGlobalInterestIndex_wad() / userPosition.interestIndexAtLastUpdate_wad;
    }

    function getPositionCollateral(address user) external view returns (uint) {
        return userPositions[user].collateral;
    }

    // taken and modified from https://github.com/wolflo/solidity-interest-helper/blob/master/contracts/Interest.sol#L63C5
    function accrueInterest_wad(uint _principal, uint _rate_ray, uint _age) internal pure returns (uint) {
        return rmul(_principal, rpow(_rate_ray, _age));
    }
}
