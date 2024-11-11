// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/token/ERC20/ERC20.sol";
import "@openzeppelin/access/Ownable.sol";
import "@ds-math/math.sol";

import {console} from "forge-std/console.sol";

/// @title Mock Price Oracle
/// @notice A simple price oracle that returns a constant price for ETH
/// @dev Not suitable for production use
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

    /// @notice Sets the ETH price
    /// @param _ethPrice The new ETH price
    function setPrice(uint _ethPrice) external onlyOwner {
        ethPrice = _ethPrice;
    }
}

/*
    Stable is a simple stablecoin protocol with interest accrued on debts
    Interest is accrued per second. The interest rate can be changed by the owner at any time.
    A global interest index is used to calculate the accrued debt on a position at a given time.

    Loans can be taken out repeatedly, and can be partially repaid.
    However, collateral cannot be added to or partially withdrawn from a position.

    Liquidators can liquidate undercollateralized positions.
    They are incentivized to do so for any position that has a collateral ratio above 1.0x.
    Thus this protocol becomes unstable and likely insolvent if the price of ETH falls so quickly
    that positions begin to fall below 1.0x collateral ratio before liquidators catch on.
    Gas costs of liquidators make this even worse.
    I am considering this issue out of scope for this task, but some ideas:
    - Adjust POSITION_LIQUIDATE_LTV to be higher.
    - Remove/lower barriers to entry to liquidators, i.e. build good dashboards etc.
    - A minimum position size could be enforced to mitigate gas cost concerns for liquidators.
*/

/// @title Stable
/// @notice A simple stablecoin protocol with interest-bearing collateralized debt positions
/// @dev Inherits from ERC20, Ownable, and DSMath
contract Stable is ERC20, Ownable, DSMath {
    MockPriceOracle priceOracle;

    // A user can take debt as long as the collateral is valued at this ratio of the debt or above
    uint constant POSITION_TAKELOAN_LTV_WAD = 1.5e18; // 1.5
    // A liquidator can liquidate a position if the collateral is valued at this ratio of the debt or below
    uint constant POSITION_LIQUIDATE_LTV_WAD = 1.1e18; // 1.1

    uint public interestRatePerSecond_ray;
    // The global interest index, which is used to calculate the interest accrued on a position
    uint public globalInterestIndex_wad;
    // The timestamp of the last interest rate change
    uint public lastInterestChangeTimestamp;

    /// @notice Struct representing a user's collateralized debt position
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
    
    /// @notice Initializes the Stable contract
    /// @param _priceOracle Address of the price oracle contract
    /// @param _interestRatePerSecond_ray Initial per-second interest rate in ray format
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

    /// @notice Updates the protocol's interest rate
    /// @param _interestRatePerSecond_ray New per-second interest rate in ray format
    function updateInterestRate(uint _interestRatePerSecond_ray) external onlyOwner {
        accrueGlobalInterest();

        interestRatePerSecond_ray = _interestRatePerSecond_ray;
        emit InterestRateUpdated(_interestRatePerSecond_ray);
    }

    // --- POSITION HOLDER FUNCTIONS ---

    /// @notice Opens a new collateralized debt position
    /// @dev Requires ETH to be sent with the transaction
    function openPosition() external payable {
        require(msg.value > 0, "Deposit must be greater than 0");

        Position storage userPosition = userPositions[msg.sender];

        require(userPosition.collateral == 0, "User already has position open");

        userPosition.collateral = msg.value;
        userPosition.interestIndexAtLastUpdate_wad = calcCurrentGlobalInterestIndex_wad();

        emit PositionOpened(msg.sender, msg.value);
    }

    /// @notice Takes out a loan against existing collateral
    /// @param loanAmount Amount of stablecoins to borrow
    function takeLoan(uint loanAmount) external {
        require(loanAmount > 0, "Loan amount must be greater than 0");

        accrueUserInterest(msg.sender);

        Position storage userPosition = userPositions[msg.sender];

        uint requiredCollateral_debtDenominated = wmul((userPosition.debt + loanAmount), POSITION_TAKELOAN_LTV_WAD);
        uint requiredCollateral = wdiv(requiredCollateral_debtDenominated, priceOracle.ethPrice());

        require(userPosition.collateral >= requiredCollateral, "Not enough collateral to take this loan");

        userPosition.debt += loanAmount;

        _mint(msg.sender, loanAmount);
        emit PositionBorrowed(msg.sender, loanAmount);
    }

    /// @notice Repays part or all of an outstanding loan
    /// @param repayAmount Amount of stablecoins to repay
    function repayLoan(uint repayAmount) public {
        require(repayAmount > 0, "Repay amount must be greater than 0");

        require(getPositionDebtWithInterest(msg.sender) >= repayAmount, "Repay amount must be equal to or less than debt");

        accrueUserInterest(msg.sender);

        repayLoanFromMsgSender(msg.sender, repayAmount);
    }

    /// @notice Closes a position by repaying all debt and withdrawing collateral
    function closePosition() external {
        Position storage userPosition = userPositions[msg.sender];

        require(userPosition.collateral > 0, "User does not have a position open");

        accrueUserInterest(msg.sender);

        // Repay loan if necessary
        repayLoanFromMsgSender(msg.sender, userPosition.debt);

        uint collateralToReturn = userPosition.collateral;
        userPosition.collateral = 0;

        payable(msg.sender).transfer(collateralToReturn);

        emit PositionClosed(msg.sender);
    }

    // --- LIQUIDATOR FUNCTIONS ---

    /// @notice Liquidates an undercollateralized position
    /// @param user Address of the position to liquidate
    function liquidatePosition(address user) external {
        Position storage userPosition = userPositions[user];

        require(userPosition.collateral > 0, "User does not have a position open");

        uint accruedDebt = getPositionDebtWithInterest(user);

        uint requiredCollateral_debtDenominated = wmul(accruedDebt, POSITION_LIQUIDATE_LTV_WAD);
        uint requiredCollateral = wdiv(requiredCollateral_debtDenominated, priceOracle.ethPrice());

        require(userPosition.collateral < requiredCollateral, "User is not undercollateralized");

        accrueUserInterest(user);

        repayLoanFromMsgSender(user, userPosition.debt);

        uint collateralToReturn = userPosition.collateral;
        userPosition.collateral = 0;

        payable(msg.sender).transfer(collateralToReturn);

        emit PositionLiquidated(user);
    }

    // --- INTERNAL FUNCTIONS ---

    /// @notice Updates the global interest index if time has passed
    function accrueGlobalInterest() internal {
        uint secondsElapsed = block.timestamp - lastInterestChangeTimestamp;

        if (secondsElapsed > 0) {
            globalInterestIndex_wad = calcCurrentGlobalInterestIndex_wad();

            lastInterestChangeTimestamp = block.timestamp;
        }
    }

    /// @notice Updates a user's position with accrued interest
    /// @param user Address of the position to update
    function accrueUserInterest(address user) internal {
        userPositions[user].debt = getPositionDebtWithInterest(user);
        userPositions[user].interestIndexAtLastUpdate_wad = calcCurrentGlobalInterestIndex_wad();
        // todo: the above results in two calls to calcCurrentGlobalInterestIndex_wad; code should be reorganized to avoid this.
    }

    /// @notice Internal function to handle loan repayment logic
    /// @param who Address of the position being repaid
    /// @param repayAmount Amount being repaid
    function repayLoanFromMsgSender(address who, uint repayAmount) internal {
        userPositions[who].debt -= repayAmount;
        _burn(msg.sender, repayAmount);
        emit PositionRepaid(who, repayAmount);
    }

    // --- PURE/VIEW FUNCTIONS ---

    /// @notice Gets a position's current debt including accrued interest
    /// @param user Address of the position
    /// @return Current debt with interest
    function getPositionDebtWithInterest(address user) public view returns (uint) {
        Position storage userPosition = userPositions[user];

        if (userPosition.debt == 0) {
            return 0;
        }

        return wdiv(wmul(userPosition.debt, calcCurrentGlobalInterestIndex_wad()),
                    userPosition.interestIndexAtLastUpdate_wad
                   );
    }

    /// @notice Gets a position's collateral amount
    /// @param user Address of the position
    /// @return Amount of collateral
    function getPositionCollateral(address user) external view returns (uint) {
        return userPositions[user].collateral;
    }

    /// @notice Calculates the current global interest index
    /// @return Current global interest index in wad format
    function calcCurrentGlobalInterestIndex_wad() internal view returns (uint) {
        uint secondsElapsed = block.timestamp - lastInterestChangeTimestamp;

        return accrueInterest_wad(globalInterestIndex_wad, interestRatePerSecond_ray, secondsElapsed);
    }

    // taken and modified from https://github.com/wolflo/solidity-interest-helper/blob/master/contracts/Interest.sol#L63C5
    /// @notice Calculates interest accrued over a time period
    /// @param _principal Principal amount
    /// @param _rate_ray Interest rate per second in ray
    /// @param _age Number of seconds elapsed
    /// @return Interest accrued in wad format
    function accrueInterest_wad(uint _principal, uint _rate_ray, uint _age) internal pure returns (uint) {
        return rmul(_principal, rpow(_rate_ray, _age));
    }
}