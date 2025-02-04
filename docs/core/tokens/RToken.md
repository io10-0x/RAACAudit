
# RToken

## Overview

The RToken is an implementation of the interest-bearing token for the RAAC lending protocol. It represents a user's deposit in the Reserve Pool and accrues interest over time using an index-based system similar to Aave's AToken.

## Purpose

- Represent user deposits in the RAAC lending protocol
- Handle minting and burning of RTokens
- Manage deposit balances that increase over time due to interest accrual
- Provide scaled and non-scaled balance information

## Key Functions

| Function Name | Description | Access | Parameters |
|---------------|-------------|--------|------------|
| setReservePool | Sets the Reserve Pool address | Owner Only | `newReservePool`: Address of new Reserve Pool |
| updateLiquidityIndex | Updates the liquidity index | Reserve Pool Only | `newLiquidityIndex`: New liquidity index value |
| mint | Mints RTokens to a user | Reserve Pool Only | `caller`: Mint initiator<br>`onBehalfOf`: Token recipient<br>`amount`: Amount to mint<br>`index`: Current liquidity index |
| burn | Burns RTokens from a user | Reserve Pool Only | `from`: Burn from address<br>`receiverOfUnderlying`: Asset recipient<br>`amount`: Amount to burn<br>`index`: Current liquidity index |
| balanceOf | Returns user's scaled balance | Public View | `account`: User address |
| totalSupply | Returns scaled total supply | Public View | None |
| transfer | Transfers scaled RTokens | Public | `recipient`: Transfer recipient<br>`amount`: Transfer amount |
| transferFrom | Transfers scaled RTokens | Public | `sender`: Transfer from address<br>`recipient`: Transfer recipient<br>`amount`: Transfer amount |
| scaledBalanceOf | Returns non-scaled balance | Public View | `user`: User address |
| scaledTotalSupply | Returns non-scaled supply | Public View | None |
| setBurner | Sets burner address | Owner Only | `burner`: New burner address |
| setMinter | Sets minter address | Owner Only | `minter`: New minter address |
| getAssetAddress | Returns underlying asset | Public View | None |
| transferAsset | Transfers underlying asset | Reserve Pool Only | `user`: Asset recipient<br>`amount`: Transfer amount |
| calculateDustAmount | Calculates unclaimed dust | Public View | None |
| rescueToken | Rescues mistakenly sent tokens | Reserve Pool Only | `tokenAddress`: Token to rescue<br>`recipient`: Rescue recipient<br>`amount`: Amount to rescue |
| transferAccruedDust | Transfers accrued dust | Reserve Pool Only | `recipient`: Dust recipient<br>`amount`: Amount to transfer |

## Implementation Details

The RToken is implemented in the RToken.sol contract.

Key features of the implementation include:

- Inherits from ERC20 and ERC20Permit for standard token functionality
- Uses WadRayMath library for precise calculations
- Implements index-based interest accrual system
- Tracks user state via UserState struct mapping
- Overrides transfer functions to use scaled amounts
- Includes dust collection and token rescue capabilities
- Validates addresses and amounts
- Emits events for key state changes

## State Variables

- _reservePool: Address of Reserve Pool contract
- _minter: Address of authorized minter
- _burner: Address of authorized burner  
- _assetAddress: Address of underlying asset
- _liquidityIndex: Current liquidity index
- _userState: Mapping of user addresses to UserState structs

## Events

| Name | Description |
|------|-------------|
| ReservePoolUpdated | Emitted when the Reserve Pool address is updated |
| LiquidityIndexUpdated | Emitted when the liquidity index is updated |
| Mint | Emitted when tokens are minted |
| Burn | Emitted when tokens are burned |
| BalanceTransfer | Emitted during a token transfer |
| BurnerSet | Emitted when the burner address is set |
| MinterSet | Emitted when the minter address is set |
| DustTransferred | Emitted when dust is transferred to a recipient |

## Error Conditions

| Name | Description |
|------|-------------|
| OnlyReservePool | Reserve pool modifier requirement not met |
| InvalidAddress | Zero address provided |
| InvalidAmount | Zero or invalid amount provided |
| CannotRescueMainAsset | Attempt to rescue the main asset |
| NoDust | No dust available to transfer |

## Interactions

The RToken contract interacts with:

- Reserve Pool (LendingPool): for minting, burning, and updating the liquidity index
- Users: for transfers, deposits, and withdrawals
- Underlying asset (e.g., crvUSD): for transferring the actual asset during mints and burns
