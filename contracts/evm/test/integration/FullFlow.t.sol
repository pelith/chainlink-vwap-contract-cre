// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {VWAPRFQSpot} from "../../src/VWAPRFQSpot.sol";
import {ChainlinkVWAPAdapter} from "../../src/ChainlinkVWAPAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockForwarder} from "../mocks/MockForwarder.sol";

/// @title FullFlow Integration Test
/// @notice End-to-end integration test demonstrating the complete lifecycle
contract FullFlowTest is Test {
    MockERC20 usdc;
    MockERC20 weth;
    MockForwarder forwarder;
    ChainlinkVWAPAdapter adapter;
    VWAPRFQSpot spot;

    uint256 constant REFUND_GRACE = 7 days;

    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy mock forwarder
        forwarder = new MockForwarder();

        // Deploy adapter (uses forwarder)
        adapter = new ChainlinkVWAPAdapter(address(forwarder));

        // Deploy spot contract
        spot = new VWAPRFQSpot(address(usdc), address(weth), address(adapter), REFUND_GRACE);

        // Label addresses for better trace readability
        vm.label(address(usdc), "USDC");
        vm.label(address(weth), "WETH");
        vm.label(address(forwarder), "MockForwarder");
        vm.label(address(adapter), "ChainlinkVWAPAdapter");
        vm.label(address(spot), "VWAPRFQSpot");
    }

    /// @notice Test 1: Full lifecycle with deltaBps=0 (no premium)
    function test_FullLifecycle_NoPremium() public {
        console.log("\n=== TEST 1: Full Lifecycle (deltaBps=0) ===\n");

        // 1. Setup: Create maker and taker
        (address maker, uint256 makerPk) = makeAddrAndKey("maker");
        address taker = makeAddr("taker");
        vm.label(maker, "Maker");
        vm.label(taker, "Taker");

        // Mint tokens
        weth.mint(maker, 1e18); // Maker has 1 WETH
        usdc.mint(taker, 2000e6); // Taker has 2000 USDC

        console.log("Initial balances:");
        console.log("  Maker WETH:", weth.balanceOf(maker));
        console.log("  Taker USDC:", usdc.balanceOf(taker));

        // 2. Maker creates and signs order
        VWAPRFQSpot.Order memory order = VWAPRFQSpot.Order({
            maker: maker,
            makerIsSellETH: true, // Maker sells WETH for USDC
            amountIn: 1e18, // 1 WETH
            minAmountOut: 1800e6, // Min 1800 USDC
            deltaBps: 0, // No premium
            salt: 1,
            deadline: block.timestamp + 1 days
        });

        bytes32 orderHash = spot.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("\nOrder created:");
        console.log("  Maker sells: 1 WETH");
        console.log("  Taker must provide at least: 1800 USDC");
        console.log("  Delta BPS: 0");

        // 3. Taker fills order
        vm.startPrank(maker);
        weth.approve(address(spot), 1e18);
        vm.stopPrank();

        vm.startPrank(taker);
        usdc.approve(address(spot), 2000e6);
        bytes32 tradeId = spot.fill(order, signature, 2000e6);
        vm.stopPrank();

        VWAPRFQSpot.Trade memory trade = spot.getTrade(tradeId);

        console.log("\nTrade filled:");
        console.log("  Trade ID:", vm.toString(tradeId));
        console.log("  Start time:", trade.startTime);
        console.log("  End time:", trade.endTime);
        console.log("  Maker deposited: 1 WETH");
        console.log("  Taker deposited: 2000 USDC");

        // Verify funds locked in contract
        assertEq(weth.balanceOf(address(spot)), 1e18, "Contract should hold 1 WETH");
        assertEq(usdc.balanceOf(address(spot)), 2000e6, "Contract should hold 2000 USDC");
        assertEq(weth.balanceOf(maker), 0, "Maker should have 0 WETH");
        assertEq(usdc.balanceOf(taker), 0, "Taker should have 0 USDC");

        // 4. Time passes (12 hours VWAP window)
        vm.warp(trade.endTime);
        console.log("\n[TIME] Warped to trade.endTime:", block.timestamp);

        // 5. Chainlink DON publishes VWAP
        // Price = 2000 USDC/ETH
        // Oracle format: (USDC per ETH) * 1e6 = 2000 * 1e6 = 2_000_000_000 = 2e9
        uint256 vwapPrice = 2_000_000_000;
        bytes memory report = abi.encode(trade.startTime, trade.endTime, vwapPrice);
        
        forwarder.submitReport(address(adapter), report);
        
        console.log("\n[VWAP] Report published:");
        console.log("  Price: 2000 USDC/ETH");
        
        // Verify price is available
        assertTrue(
            adapter.isPriceAvailable(trade.startTime, trade.endTime),
            "Price should be available after report"
        );

        // 6. Settle the trade
        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);

        spot.settle(tradeId);

        uint256 makerUsdcAfter = usdc.balanceOf(maker);
        uint256 takerWethAfter = weth.balanceOf(taker);

        console.log("\n[SETTLE] Trade settled:");
        console.log("  Maker received USDC:", makerUsdcAfter - makerUsdcBefore);
        console.log("  Taker received WETH:", takerWethAfter - takerWethBefore);

        // 7. Verify settlement
        // At price 2000 USDC/ETH:
        // 1 WETH should exchange for 2000 USDC exactly
        assertEq(makerUsdcAfter, 2000e6, "Maker should receive 2000 USDC");
        assertEq(takerWethAfter, 1e18, "Taker should receive 1 WETH");

        // Verify no leftover funds in contract (full utilization)
        assertEq(weth.balanceOf(address(spot)), 0, "No WETH should remain in contract");
        assertEq(usdc.balanceOf(address(spot)), 0, "No USDC should remain in contract");

        // Verify trade status updated
        VWAPRFQSpot.Trade memory settledTrade = spot.getTrade(tradeId);
        assertEq(uint256(settledTrade.status), uint256(VWAPRFQSpot.Status.Settled), "Trade should be settled");

        console.log("\n[SUCCESS] Test 1 Complete: Perfect exchange at VWAP price!\n");
    }

    /// @notice Test 2: Lifecycle with deltaBps=100 (1% maker premium)
    function test_FullLifecycle_WithPremium() public {
        console.log("\n=== TEST 2: Full Lifecycle (deltaBps=100, 1% premium) ===\n");

        // 1. Setup
        (address maker, uint256 makerPk) = makeAddrAndKey("maker2");
        address taker = makeAddr("taker2");
        vm.label(maker, "Maker2");
        vm.label(taker, "Taker2");

        // Mint tokens
        weth.mint(maker, 1e18); // Maker has 1 WETH
        usdc.mint(taker, 2100e6); // Taker has 2100 USDC (extra for premium)

        console.log("Initial balances:");
        console.log("  Maker WETH:", weth.balanceOf(maker));
        console.log("  Taker USDC:", usdc.balanceOf(taker));

        // 2. Maker creates order with 1% premium
        VWAPRFQSpot.Order memory order = VWAPRFQSpot.Order({
            maker: maker,
            makerIsSellETH: true,
            amountIn: 1e18, // 1 WETH
            minAmountOut: 1800e6, // Min 1800 USDC
            deltaBps: 100, // 1% premium (100 bps)
            salt: 2,
            deadline: block.timestamp + 1 days
        });

        bytes32 orderHash = spot.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("\nOrder created:");
        console.log("  Delta BPS: 100 (1% premium)");
        console.log("  Adjusted price = VWAP * 1.01");

        // 3. Fill order
        vm.startPrank(maker);
        weth.approve(address(spot), 1e18);
        vm.stopPrank();

        vm.startPrank(taker);
        usdc.approve(address(spot), 2100e6);
        bytes32 tradeId = spot.fill(order, signature, 2100e6);
        vm.stopPrank();

        VWAPRFQSpot.Trade memory trade = spot.getTrade(tradeId);

        console.log("\nTrade filled:");
        console.log("  Maker deposited: 1 WETH");
        console.log("  Taker deposited: 2100 USDC");

        // 4. Time warp
        vm.warp(trade.endTime);
        console.log("\n[TIME] Warped to trade.endTime");

        // 5. Publish VWAP (same 2000 USDC/ETH)
        // Oracle format: (USDC per ETH) * 1e6 = 2000 * 1e6 = 2_000_000_000
        uint256 vwapPrice = 2_000_000_000;
        bytes memory report = abi.encode(trade.startTime, trade.endTime, vwapPrice);
        forwarder.submitReport(address(adapter), report);

        console.log("\n[VWAP] Report published:");
        console.log("  Base price: 2000 USDC/ETH");
        console.log("  Adjusted price (with 1% premium): 2020 USDC/ETH");

        // 6. Settle
        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);

        spot.settle(tradeId);

        uint256 makerUsdcAfter = usdc.balanceOf(maker);
        uint256 takerWethAfter = weth.balanceOf(taker);

        console.log("\n[SETTLE] Trade settled:");
        console.log("  Maker received USDC:", makerUsdcAfter - makerUsdcBefore);
        console.log("  Taker received WETH:", takerWethAfter - takerWethBefore);

        // 7. Verify premium applied
        // Adjusted price = 2000 * 1.01 = 2020 USDC/ETH
        // 1 WETH should get maker 2020 USDC
        assertEq(makerUsdcAfter, 2020e6, "Maker should receive 2020 USDC (with 1% premium)");
        assertEq(takerWethAfter, 1e18, "Taker should receive 1 WETH");

        // Verify taker gets refund of unused USDC
        uint256 takerRefund = usdc.balanceOf(taker);
        assertEq(takerRefund, 80e6, "Taker should get 80 USDC refund (2100 - 2020)");

        console.log("  Taker refund:", takerRefund, "USDC");

        // Verify no WETH left, and only taker's refund USDC remains
        assertEq(weth.balanceOf(address(spot)), 0, "No WETH should remain");
        assertEq(usdc.balanceOf(address(spot)), 0, "No USDC should remain");

        console.log("\n[SUCCESS] Test 2 Complete: Maker gets premium, taker gets refund!\n");
    }
}
