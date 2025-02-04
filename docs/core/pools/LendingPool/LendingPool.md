# LendingPool

## Overview

The LendingPool is the main contract for the RAAC lending protocol, managing lending and borrowing operations using RAAC NFTs as collateral. It implements an index-based system for interest accrual and a dynamic interest rate model.

![alt text](<./lendingPoolDiagram.png>)

## Purpose

- Facilitate lending and borrowing operations using RAAC NFTs as collateral
- Manage loan data and interest calculations
- Implement a dynamic interest rate model based on pool utilization around a prime rate
- Handle liquidations and provide a grace period for users to repay
- Ensure secure and efficient token transfers

## Key Functions

| Function Name | Description | Access | Parameters |
|---------------|-------------|--------|------------|
| deposit | Allows a user to deposit reserve assets and receive RTokens | Public | `amount`: The amount of reserve assets to deposit |
| withdraw | Allows a user to withdraw reserve assets by burning RTokens | Public | `amount`: The amount of reserve assets to withdraw |
| depositNFT | Allows a user to deposit an NFT as collateral | Public | `tokenId`: The token ID of the NFT to deposit |
| withdrawNFT | Allows a user to withdraw an NFT | Public | `tokenId`: The token ID of the NFT to withdraw |
| borrow | Allows a user to borrow reserve assets using their NFT collateral | Public | `amount`: The amount of reserve assets to borrow |
| repay | Allows a user to repay their borrowed reserve assets | Public | `amount`: The amount to repay |
| repayOnBehalf | Allows a user to repay borrowed reserve assets on behalf of another user | Public | `amount`: The amount to repay<br>`onBehalfOf`: The address of the user whose debt is being repaid |
| updateState | Updates the state of the lending pool | Public | None |
| initiateLiquidation | Allows anyone to initiate the liquidation process for a user | Public | `userAddress`: The address of the user to liquidate |
| closeLiquidation | Allows a user to repay their debt and close the liquidation within the grace period | Public | None |
| finalizeLiquidation | Allows the Stability Pool to finalize the liquidation after grace period expires | Stability Pool Only | `userAddress`: The address of the user being liquidated |
| calculateHealthFactor | Calculates the health factor for a user | Public View | `userAddress`: The address of the user |
| getUserCollateralValue | Gets the total collateral value for a user | Public View | `userAddress`: The address of the user |
| getUserDebt | Gets the user's debt including interest | Public View | `userAddress`: The address of the user |
| getNFTPrice | Gets the current price of an NFT from the oracle | Public View | `tokenId`: The token ID of the NFT |
| getNormalizedIncome | Gets the reserve's normalized income | Public View | None |
| getNormalizedDebt | Gets the reserve's normalized debt | Public View | None |
| getAllUserData | Gets all user data including NFT token IDs, debt balance, collateral value, liquidation status, and reserve indices | Public View | `userAddress`: The address of the user |
| setParameter | Sets a parameter value | Owner Only | `param`: The parameter to update<br>`newValue`: The new value to set |
| setPrimeRate | Sets the prime rate of the reserve | Prime Rate Oracle Only | `newPrimeRate`: The new prime rate |
| setProtocolFeeRate | Sets the protocol fee rate | Owner Only | `newProtocolFeeRate`: The new protocol fee rate |
| setStabilityPool | Sets the address of the Stability Pool | Owner Only | `newStabilityPool`: The new Stability Pool address |
| transferAccruedDust | Transfers accrued dust to a recipient | Owner Only | `recipient`: The address to receive the dust<br>`amountUnderlying`: The amount of dust to transfer |

## Implementation Details

The LendingPool is implemented in the LendingPool.sol contract.

Key features of the implementation include:

- Uses OpenZeppelin contracts for security (ReentrancyGuard, Pausable, Ownable)
- Implements ERC721Holder for handling NFT transfers
- Uses SafeERC20 for secure token transfers
- Implements an index-based system for interest accrual, similar to Compound's cToken model
- Manages loan data using a mapping of user addresses to UserData structures
- Includes functions for depositing, withdrawing, borrowing, and repaying
- Implements a liquidation process with a grace period
- Uses ReserveLibrary for managing reserve data and calculations
- Interacts with RToken and DebtToken for managing user positions
- Integrates with Curve crvUSD vault for liquidity management

## Interactions

The LendingPool contract interacts with:

- RAAC NFT: for collateral management
- RAACHousePrices: for fetching current house prices to determine borrowing limits
- crvUSDToken: for lending and borrowing operations
- RToken: for managing user deposits and withdrawals
- DebtToken: for managing user debt positions
- Stability Pool: for allowing unclosed liquidations
- Curve crvUSD Vault: for liquidity management

## Notes

While the debt accruing is compounding, the liquidity rate is linear.  
As such, the transferAccruedDust exist so those funds can be sent to the Stability Pool for liquidation events.
