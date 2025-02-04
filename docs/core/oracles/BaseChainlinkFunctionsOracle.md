# BaseChainlinkFunctionsOracle

## Overview

The BaseChainlinkFunctionsOracle is a Chainlink Functions-enabled abstract oracle that inherits from FunctionsClient and ConfirmedOwner (from shared `@chainlink/contracts`).  
It allow for inheriting contracts to perform fetch and update of pricing data from off-chain APIs. It acts as a secure bridge between the RAAC protocol and external real estate / pools pricing data sources.

## Purpose

- Provide base functionality for real-time pricing data update from off-chain sources
- Manage Chainlink Functions requests and responses lifecycle
- Provide a trusted feed base for the RAAC protocol
- Ensure data integrity through owner-controlled updates
- Handle response processing through hooks

## Access Control

The contract implements access control with distinct roles:

| Role | Description |
|------|-------------|
| Owner | Can send requests and manage DON ID |
| Router | Chainlink Functions Router that processes requests |

## Key Functions

| Name | Description | Access | Parameters |
|------|-------------|---------|------------|
| sendRequest | Triggers an on-demand Functions request | Owner | `source`: JavaScript code <br> `secretsLocation`: Location enum <br> `encryptedSecretsReference`: bytes <br> `args`: string[] <br> `bytesArgs`: bytes[] <br> `subscriptionId`: uint64 <br> `callbackGasLimit`: uint32 |
| setDonId | Updates the DON ID | Owner | `newDonId`: bytes32 |
| _beforeFulfill | Hook called before fulfillment | Internal Virtual | `args`: string[] |
| _processResponse | Hook for processing response | Internal Virtual | `response`: bytes |
| fulfillRequest | Processes oracle response | Internal Override | `requestId`: bytes32 <br> `response`: bytes <br> `err`: bytes |

## Implementation Details

The component implements:

- Integration with Chainlink Functions Client
- Request/response lifecycle management
- Error handling for failed requests
- Virtual hooks for customizing behavior
- State tracking for last request/response

Dependencies:

- @chainlink/contracts/FunctionsClient
- @chainlink/contracts/ConfirmedOwner
- @chainlink/contracts/FunctionsRequest

## Events

| Name | Type | Description |
|------|------|-------------|
| donId | bytes32 | DON ID for Functions requests |
| s_lastRequestId | bytes32 | ID of last request made |
| s_lastResponse | bytes | Last successful response |
| s_lastError | bytes | Last error received |

## Error Conditions

| Name | Description |
|------|-------------|
| FulfillmentFailed | Oracle response processing failed |

### Test Setup Requirements

1. Contract Setup:
   - Deploy mock Functions Router
   - Deploy inheriting oracle contract
   - Set valid DON ID
   - Setup Functions subscription

2. Test Categories:
   - Access control verification
   - Request handling
   - Response processing
   - Hook execution
   - Error handling

## Notes

- Abstract contract - must be inherited
- Requires valid Chainlink Functions subscription
- DON ID must be set during construction
- Only processes valid responses
- Provides hooks for custom behavior
- Owner controls request permissions.
