// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVWAPOracle} from "../../src/IVWAPOracle.sol";

/// @title MockOracle
/// @notice Minimal IVWAPOracle mock for testing
contract MockOracle is IVWAPOracle {
    error OracleDataNotAvailable();

    /// @notice Mapping of interval key to price
    mapping(bytes32 => uint256) public prices;

    /// @notice Set price for a specific interval
    /// @param startTime Interval start time
    /// @param endTime Interval end time
    /// @param price Price to return (0 will revert on getPrice)
    function setPrice(uint256 startTime, uint256 endTime, uint256 price) external {
        bytes32 key = keccak256(abi.encode(startTime, endTime));
        prices[key] = price;
    }

    /// @notice Get the VWAP price for a specified time interval
    /// @param startTime Interval start time
    /// @param endTime Interval end time
    /// @return price VWAP price value
    /// @dev Reverts OracleDataNotAvailable if price is 0 (mimics real adapter)
    function getPrice(uint256 startTime, uint256 endTime) external view returns (uint256 price) {
        bytes32 key = keccak256(abi.encode(startTime, endTime));
        price = prices[key];
        if (price == 0) revert OracleDataNotAvailable();
        return price;
    }
}
