// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/token/ERC20/ERC20.sol";
import "@openzeppelin/access/Ownable.sol";

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

contract Stable is ERC20, Ownable {
    MockPriceOracle priceOracle;

    uint constant POSITION_TAKELOAN_LTV = 1.5e18; // 1.5
    uint constant POSITION_LIQUIDATE_LTV = 1.1e18; // 1.1

    uint public annualInterestRate;
    uint public globalInterestIndex;
    uint public lastInterestChangeTimestamp;

    struct Position {
        uint collateral;
        uint debt;
        uint interestIndexAtLastUpdate;
    }

    mapping(address => Position) userPositions;

    event PositionOpened(address indexed user, uint amount);
    event PositionClosed(address indexed user);

    constructor(MockPriceOracle _priceOracle, uint _annualInterestRate)
        ERC20("Stable", "STBL")
        Ownable(msg.sender)
    {
        owner = msg.sender;
        priceOracle = _priceOracle;

        annualInterestRate = _annualInterestRate;
        globalInterestIndex = 1e18; // starts at 1
        lastInterestChangeTimestamp = block.timestamp;
    }

    function updateInterestRate(uint _annualInterestRate) external onlyOwner {
        accrueGlobalInterest();

        annualInterestRate = _annualInterestRate;
    }

    function openPosition() external payable {
        require(msg.value > 0, "Deposit must be greater than 0");

        Position storage userPosition = userPositions[msg.sender];

        require(userPosition.collateral == 0, "User already has position open");

        userPosition.collateral = msg.value;

        emit PositionOpened(msg.sender, msg.value);
    }

    function takeLoan(uint loanAmount) external {
        require(loanAmount > 0, "Loan amount must be greater than 0");

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
        require(userPositions[msg.sender].debt >= repayAmount, "Repay amount must be equal to or less than debt");

        _repayLoan(msg.sender, repayAmount);
    }

    function closePosition() external {
        Position storage userPosition = userPositions[msg.sender];

        require(userPosition.collateral > 0, "User does not have a position open");

        // Repay loan if necessary
        _repayLoan(msg.sender, userPosition.debt);

        uint collateralToReturn = userPosition.collateral;
        userPosition.collateral = 0;
        payable(msg.sender).transfer(collateralToReturn); // todo: better method?

        emit PositionClosed(msg.sender);
    }


}
