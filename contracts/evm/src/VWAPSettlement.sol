// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IReceiver} from "./keystone/IReceiver.sol";
import {IERC165} from "./keystone/IERC165.sol";

/// @title VWAPSettlement - receives CRE VWAP price reports keyed by orderId
/// @notice Report format reuses UpdateReserves(uint256, uint256):
///   totalMinted  = orderId
///   totalReserve = (startTime << 128) | (endTime << 64) | priceE8
contract VWAPSettlement is IReceiver {
    struct Settlement {
        uint64 startTime;
        uint64 endTime;
        uint64 priceE8;
        bool settled;
    }

    mapping(uint256 => Settlement) public settlements;

    event PriceSettled(
        uint256 indexed orderId,
        uint64 startTime,
        uint64 endTime,
        uint64 priceE8
    );

    function onReport(bytes calldata, bytes calldata report) external override {
        (uint256 orderId, uint256 packed) = abi.decode(report, (uint256, uint256));

        uint64 startTime = uint64(packed >> 128);
        uint64 endTime = uint64(packed >> 64);
        uint64 priceE8 = uint64(packed);

        require(priceE8 > 0, "price cannot be zero");
        require(endTime > startTime, "invalid time range");

        settlements[orderId] = Settlement({
            startTime: startTime,
            endTime: endTime,
            priceE8: priceE8,
            settled: true
        });

        emit PriceSettled(orderId, startTime, endTime, priceE8);
    }

    function getPrice(uint256 orderId) external view returns (uint64 startTime, uint64 endTime, uint64 priceE8) {
        Settlement storage s = settlements[orderId];
        require(s.settled, "not settled");
        return (s.startTime, s.endTime, s.priceE8);
    }

    function isSettled(uint256 orderId) external view returns (bool) {
        return settlements[orderId].settled;
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
