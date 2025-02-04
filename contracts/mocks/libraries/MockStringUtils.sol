// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../libraries/utils/StringUtils.sol";

/**
 * @title MockStringUtils
 * @dev Mock contract for testing StringUtils library functions
 */
contract MockStringUtils {
    using StringUtils for string;

    /**
     * @notice Wrapper function to test stringToUint
     * @param s The string to convert
     * @return The converted uint256
     */
    function stringToUint(string memory s) external pure returns (uint256) {
        return StringUtils.stringToUint(s);
    }
} 