// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/token/ERC20/ERC20.sol";
import "@openzeppelin/access/Ownable.sol";
import "@ds-math/math.sol";

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

contract Stable is ERC20, Ownable, DSMath {
    MockPriceOracle priceOracle;

    uint constant POSITION_TAKELOAN_LTV = 1.5e18; // 1.5
    uint constant POSITION_LIQUIDATE_LTV = 1.1e18; // 1.1

    uint public interestRatePerSecond_ray;
    uint public globalInterestIndex_wad;
    uint public lastInterestChangeTimestamp;

    struct Position {
        uint collateral;
        uint debt;
        uint interestIndexAtLastUpdate_wad;
    }

    mapping(address => Position) userPositions;

    event PositionOpened(address indexed user, uint amount);
    event PositionClosed(address indexed user);

    constructor(MockPriceOracle _priceOracle, uint _interestRatePerSecond_ray)
        ERC20("Stable", "STBL")
        Ownable(msg.sender)
    {
        priceOracle = _priceOracle;

        interestRatePerSecond_ray = _interestRatePerSecond_ray;
        globalInterestIndex_wad = 1e18; // starts at 1
        lastInterestChangeTimestamp = block.timestamp;
    }

    function updateInterestRate(uint _interestRatePerSecond_ray) external onlyOwner {
        accrueGlobalInterest();

        interestRatePerSecond_ray = _interestRatePerSecond_ray;
    }

    function accrueGlobalInterest() internal {
        uint secondsElapsed = block.timestamp - lastInterestChangeTimestamp;

        if (secondsElapsed > 0) {
            globalInterestIndex_wad = calcCurrentGlobalInterestIndex_wad();

            lastInterestChangeTimestamp = block.timestamp;
        }
    }

    function calcCurrentGlobalInterestIndex_wad() internal view returns (uint) {
        uint secondsElapsed = block.timestamp - lastInterestChangeTimestamp;

        return accrueInterest_wad(globalInterestIndex_wad, interestRatePerSecond_ray, secondsElapsed);
    }

    function getPositionDebtWithInterest(address user) internal view returns (uint) {
        Position storage userPosition = userPositions[user];

        if (userPosition.debt == 0) {
            return 0;
        }

        return userPosition.debt * calcCurrentGlobalInterestIndex_wad() / userPosition.interestIndexAtLastUpdate_wad;
    }

    function openPosition() external payable {
        require(msg.value > 0, "Deposit must be greater than 0");

        Position storage userPosition = userPositions[msg.sender];

        require(userPosition.collateral == 0, "User already has position open");

        userPosition.collateral = msg.value;
        userPosition.interestIndexAtLastUpdate_wad = calcCurrentGlobalInterestIndex_wad();

        emit PositionOpened(msg.sender, msg.value);
    }

    function accrueUserInterest(address user) internal {
        userPositions[user].debt = getPositionDebtWithInterest(user);
        userPositions[user].interestIndexAtLastUpdate_wad = calcCurrentGlobalInterestIndex_wad();
        // todo: the above results in two calls to calcCurrentGlobalInterestIndex_wad; code should be reorganized to avoid this.
    }

    function takeLoan(uint loanAmount) external {
        require(loanAmount > 0, "Loan amount must be greater than 0");

        accrueUserInterest(msg.sender);

        Position storage userPosition = userPositions[msg.sender];

        uint requiredCollateral_debtDenominated = ((userPosition.debt + loanAmount) * POSITION_TAKELOAN_LTV) / 100;
        uint requiredCollateral = requiredCollateral_debtDenominated / priceOracle.ethPrice();

        require(userPosition.collateral >= requiredCollateral, "Not enough collateral to take this loan");

        userPosition.debt += loanAmount;

        _mint(msg.sender, loanAmount);
    }

    function _repayLoan(address who, uint repayAmount) internal {
        userPositions[who].debt -= repayAmount;
        _burn(msg.sender, repayAmount);
    }

    function repayLoan(uint repayAmount) public {
        require(repayAmount > 0, "Repay amount must be greater than 0");

        accrueUserInterest(msg.sender);
        // todo: should this be here, or in _repayLoan()?
        // just putting it up there naively would result in the next line not having the right debt value, preventing the user from ever paying back all debt.

        require(userPositions[msg.sender].debt >= repayAmount, "Repay amount must be equal to or less than debt");

        _repayLoan(msg.sender, repayAmount);
    }

    function closePosition() external {
        Position storage userPosition = userPositions[msg.sender];

        require(userPosition.collateral > 0, "User does not have a position open");

        accrueUserInterest(msg.sender);

        // Repay loan if necessary
        _repayLoan(msg.sender, userPosition.debt);

        uint collateralToReturn = userPosition.collateral;
        userPosition.collateral = 0;
        payable(msg.sender).transfer(collateralToReturn); // todo: better method?

        emit PositionClosed(msg.sender);
    }

    // taken and modified from https://github.com/wolflo/solidity-interest-helper/blob/master/contracts/Interest.sol#L63C5-L65C6
    function accrueInterest_wad(uint _principal, uint _rate_ray, uint _age) internal pure returns (uint) {
        return rmul(_principal, rpow(_rate_ray, _age));
    }
}
