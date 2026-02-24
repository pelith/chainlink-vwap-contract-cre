// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IReceiver} from "./keystone/IReceiver.sol";
import {IERC165} from "./keystone/IERC165.sol";
import {IVWAPOracle} from "./IVWAPOracle.sol";

/// @title ManualVWAPOracle
/// @notice ChainlinkVWAPAdapter with an owner backdoor for testing/staging.
/// @dev Identical behavior to ChainlinkVWAPAdapter (same hour-rounding, same key structure),
///      but forwarder is mutable and owner can inject prices directly via setPrice().
contract ManualVWAPOracle is IReceiver, IVWAPOracle {
    address public immutable owner;

    /// @notice Authorized CRE Forwarder. address(0) = anyone may call onReport.
    address public forwarder;

    mapping(bytes32 => uint256) public publishedPrices;

    event PricePublished(uint256 indexed startTime, uint256 indexed endTime, uint256 price);
    event ForwarderUpdated(address indexed previous, address indexed next);

    error NotOwner();
    error OracleDataNotAvailable();
    error UnauthorizedCaller();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner, address _forwarder) {
        owner = _owner;
        forwarder = _forwarder;
    }

    /// @notice Manually inject a VWAP price (owner only). Timestamps are hour-rounded, same as onReport.
    function setPrice(uint256 startTime, uint256 endTime, uint256 price) external onlyOwner {
        uint256 roundedStart = _roundUpToHour(startTime);
        uint256 roundedEnd = _roundUpToHour(endTime);
        bytes32 key = keccak256(abi.encode(roundedStart, roundedEnd));
        publishedPrices[key] = price;
        emit PricePublished(roundedStart, roundedEnd, price);
    }

    /// @notice Update the authorized forwarder (owner only).
    function setForwarder(address _forwarder) external onlyOwner {
        emit ForwarderUpdated(forwarder, _forwarder);
        forwarder = _forwarder;
    }

    /// @notice Identical to ChainlinkVWAPAdapter.onReport.
    function onReport(bytes calldata /*metadata*/, bytes calldata report) external override {
        address _forwarder = forwarder;
        if (_forwarder != address(0) && msg.sender != _forwarder) revert UnauthorizedCaller();

        (uint256 startTime, uint256 endTime, uint256 price) = abi.decode(report, (uint256, uint256, uint256));

        uint256 roundedStart = _roundUpToHour(startTime);
        uint256 roundedEnd = _roundUpToHour(endTime);

        bytes32 key = keccak256(abi.encode(roundedStart, roundedEnd));
        publishedPrices[key] = price;

        emit PricePublished(roundedStart, roundedEnd, price);
    }

    /// @inheritdoc IVWAPOracle
    function getPrice(uint256 startTime, uint256 endTime) external view returns (uint256 price) {
        uint256 roundedStart = _roundUpToHour(startTime);
        uint256 roundedEnd = _roundUpToHour(endTime);
        bytes32 key = keccak256(abi.encode(roundedStart, roundedEnd));
        price = publishedPrices[key];
        if (price == 0) revert OracleDataNotAvailable();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _roundUpToHour(uint256 t) private pure returns (uint256) {
        return ((t + 3599) / 3600) * 3600;
    }
}
