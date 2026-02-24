// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IReceiver} from "./keystone/IReceiver.sol";
import {IERC165} from "./keystone/IERC165.sol";
import {IVWAPOracle} from "./IVWAPOracle.sol";

/// @title ChainlinkVWAPAdapter
/// @notice Adapter for Chainlink CRE VWAP reports
/// @dev Receives VWAP data from authorized CRE Forwarder (via IReceiver) and makes it queryable
contract ChainlinkVWAPAdapter is IReceiver, IVWAPOracle {
    /// @notice Address authorized to submit price reports
    address public immutable forwarder;

    /// @notice Mapping of published VWAP prices
    /// @dev Key is keccak256(abi.encode(roundedStart, roundedEnd))
    mapping(bytes32 => uint256) public publishedPrices;

    /// @notice Emitted when a new VWAP price is published
    /// @param startTime Rounded start time of the interval
    /// @param endTime Rounded end time of the interval
    /// @param price VWAP price value
    event PricePublished(uint256 indexed startTime, uint256 indexed endTime, uint256 price);

    /// @notice Thrown when oracle data is not available for the requested interval
    error OracleDataNotAvailable();

    /// @notice Thrown when caller is not the authorized forwarder
    error UnauthorizedForwarder();

    /// @notice Thrown when forwarder address is zero
    error InvalidForwarderAddress();

    /// @notice Constructs the adapter with an authorized forwarder
    /// @param _forwarder Address authorized to submit price reports
    constructor(address _forwarder) {
        if (_forwarder == address(0)) revert InvalidForwarderAddress();
        forwarder = _forwarder;
    }

    /// @notice Receives and stores a VWAP price report from the CRE Forwarder
    /// @dev metadata is ignored; report = abi.encode(startTime, endTime, price)
    function onReport(bytes calldata /*metadata*/, bytes calldata report) external override {
        if (msg.sender != forwarder) revert UnauthorizedForwarder();

        (uint256 startTime, uint256 endTime, uint256 price) = abi.decode(report, (uint256, uint256, uint256));

        uint256 roundedStart = _roundUpToHour(startTime);
        uint256 roundedEnd = _roundUpToHour(endTime);

        bytes32 key = keccak256(abi.encode(roundedStart, roundedEnd));
        publishedPrices[key] = price;

        emit PricePublished(roundedStart, roundedEnd, price);
    }

    /// @notice Get the VWAP price for a specified time interval
    /// @param startTime Interval start time (unix timestamp)
    /// @param endTime Interval end time (unix timestamp)
    /// @return price VWAP price value
    /// @dev Reverts if price data is not available for the rounded interval
    function getPrice(uint256 startTime, uint256 endTime) external view returns (uint256 price) {
        uint256 roundedStart = _roundUpToHour(startTime);
        uint256 roundedEnd = _roundUpToHour(endTime);

        bytes32 key = keccak256(abi.encode(roundedStart, roundedEnd));
        price = publishedPrices[key];

        if (price == 0) revert OracleDataNotAvailable();

        return price;
    }

    /// @notice Check if price data is available for a time interval
    /// @param startTime Interval start time (unix timestamp)
    /// @param endTime Interval end time (unix timestamp)
    /// @return available True if price data exists for the rounded interval
    function isPriceAvailable(uint256 startTime, uint256 endTime) external view returns (bool available) {
        uint256 roundedStart = _roundUpToHour(startTime);
        uint256 roundedEnd = _roundUpToHour(endTime);

        bytes32 key = keccak256(abi.encode(roundedStart, roundedEnd));
        return publishedPrices[key] != 0;
    }

    /// @notice Get the rounded hour-aligned interval for given timestamps
    /// @param startTime Original start time
    /// @param endTime Original end time
    /// @return roundedStart Start time rounded up to the next hour
    /// @return roundedEnd End time rounded up to the next hour
    function getRoundedInterval(uint256 startTime, uint256 endTime)
        external
        pure
        returns (uint256 roundedStart, uint256 roundedEnd)
    {
        return (_roundUpToHour(startTime), _roundUpToHour(endTime));
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Internal helper to round a timestamp up to the next hour
    function _roundUpToHour(uint256 t) private pure returns (uint256) {
        return ((t + 3599) / 3600) * 3600;
    }
}
