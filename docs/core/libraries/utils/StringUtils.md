# StringUtils

## Overview

The StringUtils library provides functions for specific String manipulation.

## Purpose

- Provide standardize string manipulation

## Key Functions

| Function | Description | Parameters | Returns |
|----------|-------------|------------|---------|
| stringToUint | Converts a numeric string to uint256 | `s`: String to convert | The converted uint256 value |

### Function Details

1. **stringToUint**
   - Converts a string containing only numeric characters to a uint256 value
   - Reverts if string contains any non-numeric characters
   - For each digit, `result = result * 10 + digit`

## Implementation Details

The library implements:

- Pure Solidity functions
- Character-by-character string processing
- Input validation for numeric characters
- uint256 conversion

## Usage Guidelines

1. **Import and Usage**
   ```solidity
   using StringUtils for string;
   ```

2. **String to Uint Example**
   ```solidity
   string memory numStr = "12345";
   uint256 result = StringUtils.stringToUint(numStr); // 12345
   ```

## Error Conditions

- Reverts with `NonNumericCharacter` error:
  - When string contains any character that is not 0-9
  - Examples: letters, symbols, spaces

## Notes

- Only processes base-10 numeric strings
- No support for negative numbers or decimals
