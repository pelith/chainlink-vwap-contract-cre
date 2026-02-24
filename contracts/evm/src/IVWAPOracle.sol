// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVWAPOracle
/// @notice Interface for VWAP (Volume Weighted Average Price) oracle
/// @dev Oracle adapter implementations should revert if data is insufficient or interval is invalid
interface IVWAPOracle {
    /// @notice Get the VWAP price for a specified time interval
    /// @param startTime Interval start time (unix timestamp)
    /// @param endTime Interval end time (unix timestamp)
    /// @return price VWAP price representing the exchange rate between 1 wei ETH and
    ///         smallest unit USDC, scaled by 1e18 precision
    /// @dev Price definition: price = (USDC per 1 ETH) * 1e6 / 1e18 * 1e18
    ///      Example: If 1 ETH = 2000 USDC, returns 2,000,000,000 (2e9)
    ///      Conversion formula: usdcAmount = ethAmount * price / 1e18
    /// @dev Should revert if data is insufficient or interval is invalid
    function getPrice(uint256 startTime, uint256 endTime) external view returns (uint256 price);
}
