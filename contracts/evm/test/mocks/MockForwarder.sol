// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainlinkVWAPAdapter} from "../../src/ChainlinkVWAPAdapter.sol";

/// @title MockForwarder
/// @notice Mock Chainlink Forwarder contract for testing
/// @dev Simulates the Chainlink DON forwarder without signature verification
contract MockForwarder {
    /// @notice Emitted when a report is forwarded to an adapter
    event ForwardedReport(address indexed adapter, bytes report);

    /// @notice Submit a VWAP report to an adapter
    /// @param adapter Address of the ChainlinkVWAPAdapter
    /// @param report Encoded report containing (startTime, endTime, price)
    /// @dev In production, the real forwarder verifies DON consensus signatures
    function submitReport(address adapter, bytes calldata report) external {
        emit ForwardedReport(adapter, report);
        ChainlinkVWAPAdapter(adapter).onReport("", report);
    }
}
