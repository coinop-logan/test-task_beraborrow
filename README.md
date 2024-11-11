# Test Task - Berachain

## Setup

Get Foundry: https://book.getfoundry.sh/getting-started/installation

## Test

```
forge build
forge test
```

## Notes

More notes related to the actual implementation can be seen in src/Stable.sol.

### Interest Rate of 5% annually

The task specified that the interest rate should be set at 5% annually. However, the contract as written has an interest rate compounded per second.

To get an interest rate of 5% annually, a value of 1.00000000155 should be passed in the constructor (as a ray value, so `1.00000000155e27`)

This was calculated with the formula:

`r_s = (r_a​)^(1/31,536,000)`

where r_s is the rate per second, r_a is the rate per year (expressed as 1.05 for 5%), and 31,536,000 is the number of seconds in the year.

### More Debt Accrues than can be Repaid

Because positions' debts accrue interest, from the very first debt, the amount of debt that accrues is more than the amount of ether deposited. This means the contract will immediately become insolvent.

It's not immediately clear how to address this without going quite outside the scope of the task.

### Next steps
* Redesign the contract to address the debt accrual issue.
* Add much more comprehensive test coverage.