// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainlinkVWAPAdapter} from "../src/ChainlinkVWAPAdapter.sol";

contract ChainlinkVWAPAdapterTest is Test {
    ChainlinkVWAPAdapter public adapter;
    address public forwarder = address(0x1234);
    address public unauthorizedCaller = address(0x5678);

    event PricePublished(uint256 indexed startTime, uint256 indexed endTime, uint256 price);

    function setUp() public {
        adapter = new ChainlinkVWAPAdapter(forwarder);
    }

    // ============ Constructor Tests ============

    function test_Constructor_ZeroForwarderReverts() public {
        vm.expectRevert(ChainlinkVWAPAdapter.InvalidForwarderAddress.selector);
        new ChainlinkVWAPAdapter(address(0));
    }

    function test_Constructor_ValidForwarderSetsImmutable() public {
        ChainlinkVWAPAdapter newAdapter = new ChainlinkVWAPAdapter(forwarder);
        assertEq(newAdapter.forwarder(), forwarder);
    }

    // ============ onReport Tests ============

    function test_OnReport_UnauthorizedCallerReverts() public {
        bytes memory report = abi.encode(uint256(3600), uint256(7200), uint256(2000e9));
        
        vm.prank(unauthorizedCaller);
        vm.expectRevert(ChainlinkVWAPAdapter.UnauthorizedForwarder.selector);
        adapter.onReport("", report);
    }

    function test_OnReport_StoresPriceAtRoundedKey() public {
        uint256 startTime = 3600; // Already on boundary (1 hour)
        uint256 endTime = 7200;   // Already on boundary (2 hours)
        uint256 price = 2000e9;

        bytes memory report = abi.encode(startTime, endTime, price);
        
        vm.prank(forwarder);
        adapter.onReport("", report);

        // Verify via getPrice
        uint256 retrievedPrice = adapter.getPrice(startTime, endTime);
        assertEq(retrievedPrice, price);

        // Verify via publishedPrices mapping
        bytes32 key = keccak256(abi.encode(startTime, endTime));
        assertEq(adapter.publishedPrices(key), price);
    }

    function test_OnReport_TimestampOnBoundaryNotDoubleRounded() public {
        uint256 startTime = 7200; // Exactly on 2-hour boundary
        uint256 endTime = 10800;  // Exactly on 3-hour boundary
        uint256 price = 2500e9;

        bytes memory report = abi.encode(startTime, endTime, price);
        
        vm.prank(forwarder);
        adapter.onReport("", report);

        // Should store at same key since already aligned
        uint256 retrievedPrice = adapter.getPrice(7200, 10800);
        assertEq(retrievedPrice, price);

        // Verify the rounded interval didn't change
        (uint256 roundedStart, uint256 roundedEnd) = adapter.getRoundedInterval(7200, 10800);
        assertEq(roundedStart, 7200);
        assertEq(roundedEnd, 10800);
    }

    function test_OnReport_TimestampPastBoundaryRoundsUpToNext() public {
        uint256 startTime = 7201; // 1 second past 2-hour boundary
        uint256 endTime = 10801;  // 1 second past 3-hour boundary
        uint256 price = 1800e9;

        // Should round up to next hour: 7201 → 10800, 10801 → 14400
        uint256 expectedStart = 10800; // 3 hours
        uint256 expectedEnd = 14400;   // 4 hours

        bytes memory report = abi.encode(startTime, endTime, price);
        
        vm.prank(forwarder);
        adapter.onReport("", report);

        // Verify price stored at rounded key
        uint256 retrievedPrice = adapter.getPrice(expectedStart, expectedEnd);
        assertEq(retrievedPrice, price);

        // Verify the rounded interval
        (uint256 roundedStart, uint256 roundedEnd) = adapter.getRoundedInterval(startTime, endTime);
        assertEq(roundedStart, expectedStart);
        assertEq(roundedEnd, expectedEnd);
    }

    function test_OnReport_EmitsPricePublishedWithRoundedTimestamps() public {
        uint256 startTime = 1000;  // Will round to 3600
        uint256 endTime = 5000;    // Will round to 7200
        uint256 price = 2200e9;

        uint256 expectedStart = 3600;
        uint256 expectedEnd = 7200;

        bytes memory report = abi.encode(startTime, endTime, price);
        
        vm.expectEmit(true, true, false, true);
        emit PricePublished(expectedStart, expectedEnd, price);
        
        vm.prank(forwarder);
        adapter.onReport("", report);
    }

    function test_OnReport_OverwriteExistingPrice() public {
        uint256 startTime = 3600;
        uint256 endTime = 7200;
        uint256 price1 = 2000e9;
        uint256 price2 = 2100e9;

        // First report
        bytes memory report1 = abi.encode(startTime, endTime, price1);
        vm.prank(forwarder);
        adapter.onReport("", report1);
        
        assertEq(adapter.getPrice(startTime, endTime), price1);

        // Second report (overwrite)
        bytes memory report2 = abi.encode(startTime, endTime, price2);
        vm.prank(forwarder);
        adapter.onReport("", report2);
        
        assertEq(adapter.getPrice(startTime, endTime), price2);
    }

    // ============ getPrice Tests ============

    function test_GetPrice_ReturnsStoredPriceForMatchingRoundedInterval() public {
        uint256 startTime = 3600;
        uint256 endTime = 7200;
        uint256 price = 1900e9;

        bytes memory report = abi.encode(startTime, endTime, price);
        vm.prank(forwarder);
        adapter.onReport("", report);

        uint256 retrievedPrice = adapter.getPrice(startTime, endTime);
        assertEq(retrievedPrice, price);
    }

    function test_GetPrice_RawTimestampsSameRoundedIntervalReturnSamePrice() public {
        uint256 startTime = 3600;
        uint256 endTime = 7200;
        uint256 price = 2300e9;

        bytes memory report = abi.encode(startTime, endTime, price);
        vm.prank(forwarder);
        adapter.onReport("", report);

        // Query with different raw timestamps that round to same interval
        uint256 price1 = adapter.getPrice(1, 4000);  // Rounds to 3600, 7200
        uint256 price2 = adapter.getPrice(3599, 7199); // Rounds to 3600, 7200
        uint256 price3 = adapter.getPrice(3600, 7200); // Already aligned

        assertEq(price1, price);
        assertEq(price2, price);
        assertEq(price3, price);
    }

    function test_GetPrice_UnpublishedIntervalReverts() public {
        uint256 startTime = 3600;
        uint256 endTime = 7200;

        // No price published for this interval
        vm.expectRevert(ChainlinkVWAPAdapter.OracleDataNotAvailable.selector);
        adapter.getPrice(startTime, endTime);
    }

    // ============ isPriceAvailable Tests ============

    function test_IsPriceAvailable_FalseBeforePublish() public {
        uint256 startTime = 3600;
        uint256 endTime = 7200;

        bool available = adapter.isPriceAvailable(startTime, endTime);
        assertFalse(available);
    }

    function test_IsPriceAvailable_TrueAfterPublish() public {
        uint256 startTime = 3600;
        uint256 endTime = 7200;
        uint256 price = 2000e9;

        bytes memory report = abi.encode(startTime, endTime, price);
        vm.prank(forwarder);
        adapter.onReport("", report);

        bool available = adapter.isPriceAvailable(startTime, endTime);
        assertTrue(available);
    }

    // ============ getRoundedInterval Tests ============

    function test_GetRoundedInterval_VariousInputs() public {
        // Test 1: Already aligned
        (uint256 r1Start, uint256 r1End) = adapter.getRoundedInterval(3600, 7200);
        assertEq(r1Start, 3600);
        assertEq(r1End, 7200);

        // Test 2: One second past boundary
        (uint256 r2Start, uint256 r2End) = adapter.getRoundedInterval(3601, 7201);
        assertEq(r2Start, 7200);  // 3601 rounds up to 7200
        assertEq(r2End, 10800);   // 7201 rounds up to 10800

        // Test 3: One second before boundary
        (uint256 r3Start, uint256 r3End) = adapter.getRoundedInterval(3599, 7199);
        assertEq(r3Start, 3600);  // 3599 rounds up to 3600
        assertEq(r3End, 7200);    // 7199 rounds up to 7200

        // Test 4: Zero timestamp
        (uint256 r4Start, uint256 r4End) = adapter.getRoundedInterval(0, 1);
        assertEq(r4Start, 0);     // 0 rounds to 0 (special case)
        assertEq(r4End, 3600);    // 1 rounds up to 3600

        // Test 5: Large timestamp
        (uint256 r5Start, uint256 r5End) = adapter.getRoundedInterval(1234567890, 1234571490);
        // 1234567890 → ((1234567890 + 3599) / 3600) * 3600 = 1234569600
        // 1234571490 → ((1234571490 + 3599) / 3600) * 3600 = 1234573200
        assertEq(r5Start, 1234569600);
        assertEq(r5End, 1234573200);
    }

    function test_GetRoundedInterval_EdgeCases() public {
        // Test exact hour boundaries (should not change)
        (uint256 r1Start, uint256 r1End) = adapter.getRoundedInterval(0, 3600);
        assertEq(r1Start, 0);
        assertEq(r1End, 3600);

        // Test midnight-like timestamp (86400 = 1 day)
        (uint256 r2Start, uint256 r2End) = adapter.getRoundedInterval(86400, 90000);
        assertEq(r2Start, 86400);  // Exactly on boundary
        assertEq(r2End, 90000);    // Exactly on boundary
    }
}
