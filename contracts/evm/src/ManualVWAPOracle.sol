// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IReceiver} from "./keystone/IReceiver.sol";
import {IERC165} from "./keystone/IERC165.sol";
import {IVWAPOracle} from "./IVWAPOracle.sol";

/// @title ManualVWAPOracle
/// @notice Testing/staging oracle that accepts prices both manually (owner) and via CRE Forwarder.
/// @dev Drop-in replacement for ChainlinkVWAPAdapter.
///
///      Two ways to write prices:
///        1. setPrice(startTime, endTime, price)  — owner only, no forwarder needed
///        2. onReport(metadata, report)           — CRE Forwarder (if forwarder is set)
///                                                  or anyone (if forwarder == address(0))
///
///      Use setForwarder() to switch between open mode and locked-down CRE mode.
///      NOTE: This contract is intentionally permissive for testing. Do NOT use in production.
contract ManualVWAPOracle is IReceiver, IVWAPOracle {
    address public immutable owner;

    /// @notice Authorized CRE Forwarder for onReport.
    ///         address(0) = open mode (anyone may call onReport).
    address public forwarder;

    /// @dev key = keccak256(abi.encode(startTime, endTime)) — no hour-rounding, exact timestamps.
    mapping(bytes32 => uint256) public prices;

    event PriceSet(uint256 indexed startTime, uint256 indexed endTime, uint256 price);
    event PriceCleared(uint256 indexed startTime, uint256 indexed endTime);
    event ForwarderUpdated(address indexed previous, address indexed next);

    error NotOwner();
    error OracleDataNotAvailable();
    error UnauthorizedCaller();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param _owner    Address that may call setPrice / clearPrice / setForwarder.
    /// @param _forwarder CRE Forwarder address, or address(0) for open test mode.
    constructor(address _owner, address _forwarder) {
        owner = _owner;
        forwarder = _forwarder;
    }

    // -------------------------------------------------------------------------
    // Manual write (owner only)
    // -------------------------------------------------------------------------

    /// @notice Manually set VWAP price for a time interval.
    /// @param startTime Interval start (unix timestamp)
    /// @param endTime   Interval end   (unix timestamp)
    /// @param price     USDC per 1 ETH, scaled 1e6 (e.g. 2000 USDC/ETH → 2_000_000_000_000)
    function setPrice(uint256 startTime, uint256 endTime, uint256 price) external onlyOwner {
        bytes32 key = keccak256(abi.encode(startTime, endTime));
        prices[key] = price;
        emit PriceSet(startTime, endTime, price);
    }

    /// @notice Clear price for a time interval (causes getPrice to revert again).
    function clearPrice(uint256 startTime, uint256 endTime) external onlyOwner {
        bytes32 key = keccak256(abi.encode(startTime, endTime));
        delete prices[key];
        emit PriceCleared(startTime, endTime);
    }

    // -------------------------------------------------------------------------
    // CRE write (IReceiver)
    // -------------------------------------------------------------------------

    /// @notice Update the authorized forwarder.
    ///         Set to address(0) to allow anyone to call onReport (open test mode).
    function setForwarder(address _forwarder) external onlyOwner {
        emit ForwarderUpdated(forwarder, _forwarder);
        forwarder = _forwarder;
    }

    /// @notice Receives a VWAP price report from CRE Forwarder (or anyone in open mode).
    /// @dev report = abi.encode(startTime, endTime, price) — same encoding as ChainlinkVWAPAdapter.
    ///      No hour-rounding: key uses timestamps as-is.
    function onReport(bytes calldata /*metadata*/, bytes calldata report) external override {
        address _forwarder = forwarder;
        if (_forwarder != address(0) && msg.sender != _forwarder) revert UnauthorizedCaller();

        (uint256 startTime, uint256 endTime, uint256 price) = abi.decode(report, (uint256, uint256, uint256));

        bytes32 key = keccak256(abi.encode(startTime, endTime));
        prices[key] = price;
        emit PriceSet(startTime, endTime, price);
    }

    // -------------------------------------------------------------------------
    // Read
    // -------------------------------------------------------------------------

    /// @inheritdoc IVWAPOracle
    function getPrice(uint256 startTime, uint256 endTime) external view returns (uint256 price) {
        bytes32 key = keccak256(abi.encode(startTime, endTime));
        price = prices[key];
        if (price == 0) revert OracleDataNotAvailable();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
