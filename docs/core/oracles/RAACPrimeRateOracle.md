# RAACPrimeRateOracle

## Overview

The RAACPrimeRateOracle is a Chainlink Functions-enabled oracle that fetches and updates prime rate data from off-chain APIs. It serves as the authoritative source for prime rate updates in the RAAC lending protocol.  
It inhetics from [BaseChainlinkFunctionsOracles](core/oracles/BaseChainlinkFunctionsOracle.md)

## Purpose

- Fetch real-time prime rate data from off-chain sources
- Securely update prime rates in the LendingPool contract
- Provide a trusted prime rate feed for the lending protocol
- Track historical prime rate updates with timestamps

## Access Control

The access control are implemented in the [inherited contract](core/oracles/BaseChainlinkFunctionsOracle.md).  

## Key Functions

| Name | Description | Access | Parameters |
|------|-------------|---------|------------|
| constructor | Initializes the oracle with router, DON ID and lending pool | Public | `router`: Router address <br> `_donId`: DON ID <br> `lendingPool`: [Lending Pool](core/pools/LendingPool/LendingPool.md) contract address |
| _beforeFulfill | Hook called before fulfillment to store house ID | Internal | `args`: string[] - Arguments passed to sendRequest |
| _processResponse | Processes oracle response and updates house price | Internal | `response`: bytes - Response from oracle |

## Implementation Details

The component implements:

- Integration with Chainlink Functions Client (via BaseChainlinFunctionsOracle)
- Secure prime rate updates through oracle responses
- Error handling for failed requests
- Timestamp tracking for rate updates
- Direct integration with LendingPool contract

Dependencies:

- [BaseChainlinkFunctionsOracles](core/oracles/BaseChainlinkFunctionsOracle.md)
- ILendingPool interface

## Events

| Name | Description |
|------|-------------|
| PrimeRateUpdated | Emitted when prime rate is updated with new value |

## Error Conditions

| Name | Description |
|------|-------------|
| FulfillmentFailed | Oracle response processing failed |

### Test Setup Requirements

1. Contract Deployment:
   - Deploy MockFunctionsRouter
   - Deploy LendingPool contract
   - Deploy RAACPrimeRateOracle with router and DON ID
   - Set oracle address in LendingPool

2. Test Categories:
   - Access control verification
   - Request handling
   - Response processing
   - Rate update validation
   - Integration with LendingPool
   - Error handling

## Notes

- Requires valid Chainlink Functions subscription
- DON ID must be set during construction
- Only processes valid responses from authorized Chainlink nodes
- Prime rate updates are forwarded to LendingPool contract
- Integration setup handled through deployment process
- Rate changes may be subject to limits in LendingPool
- Historical data maintained through lastUpdateTimestamp
