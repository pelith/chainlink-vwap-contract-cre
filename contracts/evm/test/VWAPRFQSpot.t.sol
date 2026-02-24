// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VWAPRFQSpot} from "../src/VWAPRFQSpot.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract VWAPRFQSpotTest is Test {
    VWAPRFQSpot public spot;
    MockOracle public oracle;
    MockERC20 public usdc;
    MockERC20 public weth;

    uint256 public constant REFUND_GRACE = 7 days;
    uint256 public constant VWAP_WINDOW = 12 hours;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker;
    uint256 public takerPrivateKey;

    event Filled(
        address indexed maker,
        address indexed taker,
        bytes32 indexed orderHash,
        uint64 startTime,
        uint64 endTime,
        uint256 makerAmountIn,
        uint256 takerDeposit,
        bool makerIsSellETH,
        int32 deltaBps
    );

    event Settled(
        bytes32 indexed tradeId,
        uint256 usdcPerEth,
        uint256 adjustedPrice,
        uint256 makerPayout,
        uint256 takerPayout,
        uint256 makerRefund,
        uint256 takerRefund
    );

    event Refunded(
        bytes32 indexed tradeId,
        uint256 makerRefund,
        uint256 takerRefund
    );

    event Cancelled(
        address indexed maker,
        bytes32 indexed orderHash
    );

    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy oracle
        oracle = new MockOracle();

        // Deploy spot contract
        spot = new VWAPRFQSpot(address(usdc), address(weth), address(oracle), REFUND_GRACE);

        // Create maker and taker with known private keys
        makerPrivateKey = 0x1111;
        maker = vm.addr(makerPrivateKey);
        takerPrivateKey = 0x2222;
        taker = vm.addr(takerPrivateKey);

        // Fund accounts
        usdc.mint(maker, 100_000e6);  // 100k USDC
        weth.mint(maker, 100e18);     // 100 WETH
        usdc.mint(taker, 100_000e6);
        weth.mint(taker, 100e18);

        // Approve spot contract
        vm.prank(maker);
        usdc.approve(address(spot), type(uint256).max);
        vm.prank(maker);
        weth.approve(address(spot), type(uint256).max);
        vm.prank(taker);
        usdc.approve(address(spot), type(uint256).max);
        vm.prank(taker);
        weth.approve(address(spot), type(uint256).max);
    }

    // ============ Helper Functions ============

    function _signOrder(VWAPRFQSpot.Order memory order, uint256 privKey) internal view returns (bytes memory) {
        bytes32 orderHash = spot.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function _fillOrder(VWAPRFQSpot.Order memory order, bytes memory signature, uint256 takerAmountIn)
        internal
        returns (bytes32 tradeId)
    {
        vm.prank(taker);
        return spot.fill(order, signature, takerAmountIn);
    }

    function _createBasicOrder(bool makerIsSellETH, uint256 amountIn, uint256 minAmountOut)
        internal
        view
        returns (VWAPRFQSpot.Order memory)
    {
        return VWAPRFQSpot.Order({
            maker: maker,
            makerIsSellETH: makerIsSellETH,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            deltaBps: 0,
            salt: 1,
            deadline: block.timestamp + 1 hours
        });
    }

    // ============ fill() Tests ============

    function test_Fill_ExpiredOrderReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        order.deadline = block.timestamp - 1; // Already expired

        bytes memory signature = _signOrder(order, makerPrivateKey);

        vm.prank(taker);
        vm.expectRevert(VWAPRFQSpot.ExpiredOrder.selector);
        spot.fill(order, signature, 2000e6);
    }

    function test_Fill_InvalidDeltaReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        order.deltaBps = -10000; // -100%, would make adjusted price 0

        bytes memory signature = _signOrder(order, makerPrivateKey);

        vm.prank(taker);
        vm.expectRevert(VWAPRFQSpot.DeltaInvalid.selector);
        spot.fill(order, signature, 2000e6);
    }

    function test_Fill_DeltaBelowNeg10000Reverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        order.deltaBps = -10001; // Less than -100%

        bytes memory signature = _signOrder(order, makerPrivateKey);

        vm.prank(taker);
        vm.expectRevert(VWAPRFQSpot.DeltaInvalid.selector);
        spot.fill(order, signature, 2000e6);
    }

    function test_Fill_TakerAmountBelowMinReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);

        bytes memory signature = _signOrder(order, makerPrivateKey);

        vm.prank(taker);
        vm.expectRevert(VWAPRFQSpot.TakerTooSmall.selector);
        spot.fill(order, signature, 1999e6); // Below minAmountOut
    }

    function test_Fill_BadSignatureReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);

        // Sign with wrong key
        bytes memory badSignature = _signOrder(order, takerPrivateKey);

        vm.prank(taker);
        vm.expectRevert(VWAPRFQSpot.BadSignature.selector);
        spot.fill(order, badSignature, 2000e6);
    }

    function test_Fill_ReuseOrderHashReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        // First fill
        vm.prank(taker);
        spot.fill(order, signature, 2000e6);

        // Try to reuse same order
        vm.prank(taker);
        vm.expectRevert(VWAPRFQSpot.OrderUsed.selector);
        spot.fill(order, signature, 2000e6);
    }

    function test_Fill_SuccessfulMakerSellETH() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        uint256 makerWethBefore = weth.balanceOf(maker);
        uint256 takerUsdcBefore = usdc.balanceOf(taker);
        uint256 spotWethBefore = weth.balanceOf(address(spot));
        uint256 spotUsdcBefore = usdc.balanceOf(address(spot));

        uint64 expectedStartTime = uint64(block.timestamp);
        uint64 expectedEndTime = expectedStartTime + uint64(VWAP_WINDOW);

        bytes32 orderHash = spot.hashOrder(order);

        vm.expectEmit(true, true, true, true);
        emit Filled(maker, taker, orderHash, expectedStartTime, expectedEndTime, 1e18, 2000e6, true, 0);

        vm.prank(taker);
        bytes32 tradeId = spot.fill(order, signature, 2000e6);

        // Check tokens locked
        assertEq(weth.balanceOf(maker), makerWethBefore - 1e18);
        assertEq(usdc.balanceOf(taker), takerUsdcBefore - 2000e6);
        assertEq(weth.balanceOf(address(spot)), spotWethBefore + 1e18);
        assertEq(usdc.balanceOf(address(spot)), spotUsdcBefore + 2000e6);

        // Check trade created
        VWAPRFQSpot.Trade memory trade = spot.getTrade(tradeId);
        assertEq(trade.maker, maker);
        assertEq(trade.taker, taker);
        assertTrue(trade.makerIsSellETH);
        assertEq(trade.makerAmountIn, 1e18);
        assertEq(trade.takerDeposit, 2000e6);
        assertEq(trade.deltaBps, 0);
        assertEq(trade.startTime, expectedStartTime);
        assertEq(trade.endTime, expectedEndTime);
        assertEq(uint8(trade.status), uint8(VWAPRFQSpot.Status.Open));
    }

    function test_Fill_SuccessfulMakerSellUSDC() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(false, 2000e6, 1e18);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);

        vm.prank(taker);
        bytes32 tradeId = spot.fill(order, signature, 1e18);

        // Check tokens locked
        assertEq(usdc.balanceOf(maker), makerUsdcBefore - 2000e6);
        assertEq(weth.balanceOf(taker), takerWethBefore - 1e18);

        // Check trade created
        VWAPRFQSpot.Trade memory trade = spot.getTrade(tradeId);
        assertFalse(trade.makerIsSellETH);
        assertEq(trade.makerAmountIn, 2000e6);
        assertEq(trade.takerDeposit, 1e18);
    }

    function test_Fill_AfterCancelOrderHashReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes32 orderHash = spot.hashOrder(order);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        // Cancel order hash
        vm.prank(maker);
        spot.cancelOrderHash(orderHash);

        // Try to fill
        vm.prank(taker);
        vm.expectRevert(VWAPRFQSpot.OrderUsed.selector);
        spot.fill(order, signature, 2000e6);
    }

    // ============ settle() Tests ============

    function test_Settle_NonOpenTradeReverts() public {
        // This will attempt to get price from oracle which doesn't exist
        // So it will revert with OracleDataNotAvailable, not TradeNotOpen
        // A truly non-open trade would have status != Open
        
        // Create and fill an order
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);
        
        uint256 startTime = block.timestamp;
        bytes32 tradeId = _fillOrder(order, signature, 2000e6);
        
        uint256 endTime = startTime + VWAP_WINDOW;
        oracle.setPrice(startTime, endTime, 2e9);
        
        vm.warp(endTime + 1);
        
        // Settle it first
        spot.settle(tradeId);
        
        // Now try to settle again - this should revert TradeNotOpen
        vm.expectRevert(VWAPRFQSpot.TradeNotOpen.selector);
        spot.settle(tradeId);
    }

    function test_Settle_BeforeEndTimeReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        bytes32 tradeId = _fillOrder(order, signature, 2000e6);

        // Try to settle immediately (before endTime)
        vm.expectRevert(VWAPRFQSpot.NotMatured.selector);
        spot.settle(tradeId);
    }

    function test_Settle_AfterRefundGraceReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        bytes32 tradeId = _fillOrder(order, signature, 2000e6);

        // Warp past endTime + REFUND_GRACE
        vm.warp(block.timestamp + VWAP_WINDOW + REFUND_GRACE + 1);

        vm.expectRevert(VWAPRFQSpot.TooLateToSettle.selector);
        spot.settle(tradeId);
    }

    function test_Settle_OracleDataUnavailableReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        uint256 startTime = block.timestamp;
        bytes32 tradeId = _fillOrder(order, signature, 2000e6);

        // Warp past endTime but before refund grace
        vm.warp(block.timestamp + VWAP_WINDOW + 1);

        // Oracle will revert (no price set)
        vm.expectRevert(MockOracle.OracleDataNotAvailable.selector);
        spot.settle(tradeId);
    }

    function test_Settle_MakerSellETH_DeltaZero() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        uint256 startTime = block.timestamp;
        bytes32 tradeId = _fillOrder(order, signature, 2000e6);

        uint256 endTime = startTime + VWAP_WINDOW;

        // Set oracle price: 1 ETH = 2000 USDC → 2e9 (2000 * 1e6 scaled appropriately)
        oracle.setPrice(startTime, endTime, 2e9);

        // Warp to settlement time
        vm.warp(endTime + 1);

        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);

        vm.expectEmit(true, false, false, true);
        emit Settled(tradeId, 2e9, 2e9, 2000e6, 1e18, 0, 0);

        spot.settle(tradeId);

        // Maker sells 1 WETH, gets 2000 USDC (exact match)
        assertEq(usdc.balanceOf(maker), makerUsdcBefore + 2000e6);
        assertEq(weth.balanceOf(taker), takerWethBefore + 1e18);

        // Check status updated
        VWAPRFQSpot.Trade memory trade = spot.getTrade(tradeId);
        assertEq(uint8(trade.status), uint8(VWAPRFQSpot.Status.Settled));
    }

    function test_Settle_MakerSellUSDC_DeltaZero() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(false, 2000e6, 1e18);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        uint256 startTime = block.timestamp;
        bytes32 tradeId = _fillOrder(order, signature, 1e18);

        uint256 endTime = startTime + VWAP_WINDOW;

        // Set oracle price: 1 ETH = 2000 USDC
        oracle.setPrice(startTime, endTime, 2e9);

        vm.warp(endTime + 1);

        uint256 makerWethBefore = weth.balanceOf(maker);
        uint256 takerUsdcBefore = usdc.balanceOf(taker);

        spot.settle(tradeId);

        // Maker sells 2000 USDC, gets 1 WETH (exact match)
        assertEq(weth.balanceOf(maker), makerWethBefore + 1e18);
        assertEq(usdc.balanceOf(taker), takerUsdcBefore + 2000e6);
    }

    function test_Settle_PositiveDelta_AdjustedPriceHigher() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        order.deltaBps = 500; // +5%

        bytes memory signature = _signOrder(order, makerPrivateKey);

        uint256 startTime = block.timestamp;
        bytes32 tradeId = _fillOrder(order, signature, 2000e6);

        uint256 endTime = startTime + VWAP_WINDOW;

        // Oracle price: 2000 USDC/ETH → 2e9
        // Adjusted: 2e9 * (10000 + 500) / 10000 = 2.1e9 (2100 USDC/ETH)
        oracle.setPrice(startTime, endTime, 2e9);

        vm.warp(endTime + 1);

        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);
        uint256 makerWethBefore = weth.balanceOf(maker);
        uint256 takerUsdcBefore = usdc.balanceOf(taker);

        spot.settle(tradeId);

        // Maker sells 1 WETH at 2100 USDC/ETH (adjusted)
        // But taker only has 2000 USDC
        // ethUsed = min(1e18, floor(2000e6 * 1e18 / 2.1e9)) = min(1e18, 0.952380952e18)
        // usdcPaid = floor(0.952380952e18 * 2.1e9 / 1e18) = 1999999999 ≈ 2000e6
        
        // Maker gets ~2000 USDC, Taker gets ~0.952 WETH
        // Maker refund: some small amount
        assertGe(usdc.balanceOf(maker), makerUsdcBefore + 1999e6); // Gets almost all USDC
        assertGt(weth.balanceOf(maker), makerWethBefore); // Gets some refund
        assertLt(usdc.balanceOf(taker), takerUsdcBefore + 10); // Almost all USDC used
    }

    function test_Settle_NegativeDelta_AdjustedPriceLower() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 1800e6);
        order.deltaBps = -1000; // -10%

        bytes memory signature = _signOrder(order, makerPrivateKey);

        uint256 startTime = block.timestamp;
        bytes32 tradeId = _fillOrder(order, signature, 1800e6);

        uint256 endTime = startTime + VWAP_WINDOW;

        // Oracle price: 2000 USDC/ETH → 2e9
        // Adjusted: 2e9 * (10000 - 1000) / 10000 = 1.8e9 (1800 USDC/ETH)
        oracle.setPrice(startTime, endTime, 2e9);

        vm.warp(endTime + 1);

        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);

        spot.settle(tradeId);

        // Maker sells 1 WETH at 1800 USDC/ETH
        // ethUsed = min(1e18, floor(1800e6 * 1e18 / 1.8e9)) = 1e18
        // usdcPaid = floor(1e18 * 1.8e9 / 1e18) = 1800e6
        assertEq(usdc.balanceOf(maker), makerUsdcBefore + 1800e6);
        assertEq(weth.balanceOf(taker), takerWethBefore + 1e18);
    }

    function test_Settle_AlreadySettledReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        uint256 startTime = block.timestamp;
        bytes32 tradeId = _fillOrder(order, signature, 2000e6);

        uint256 endTime = startTime + VWAP_WINDOW;
        oracle.setPrice(startTime, endTime, 2000e9);

        vm.warp(endTime + 1);

        // First settle
        spot.settle(tradeId);

        // Try to settle again
        vm.expectRevert(VWAPRFQSpot.TradeNotOpen.selector);
        spot.settle(tradeId);
    }

    // ============ refund() Tests ============

    function test_Refund_BeforeRefundGraceReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        bytes32 tradeId = _fillOrder(order, signature, 2000e6);

        // Warp to just after endTime but before refund grace
        vm.warp(block.timestamp + VWAP_WINDOW + REFUND_GRACE - 1);

        vm.expectRevert(VWAPRFQSpot.RefundNotAvailable.selector);
        spot.refund(tradeId);
    }

    function test_Refund_NonOpenTradeReverts() public {
        // Create and settle a trade first
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);
        
        uint256 startTime = block.timestamp;
        bytes32 tradeId = _fillOrder(order, signature, 2000e6);
        
        uint256 endTime = startTime + VWAP_WINDOW;
        oracle.setPrice(startTime, endTime, 2e9);
        
        vm.warp(endTime + 1);
        spot.settle(tradeId);
        
        // Now try to refund a settled trade
        vm.expectRevert(VWAPRFQSpot.TradeNotOpen.selector);
        spot.refund(tradeId);
    }

    function test_Refund_MakerSellETH_BothGetOriginalDeposits() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        bytes32 tradeId = _fillOrder(order, signature, 2000e6);

        uint256 makerWethBefore = weth.balanceOf(maker);
        uint256 takerUsdcBefore = usdc.balanceOf(taker);

        // Warp past refund grace period
        vm.warp(block.timestamp + VWAP_WINDOW + REFUND_GRACE + 1);

        vm.expectEmit(true, false, false, true);
        emit Refunded(tradeId, 1e18, 2000e6);

        spot.refund(tradeId);

        // Both get their deposits back
        assertEq(weth.balanceOf(maker), makerWethBefore + 1e18);
        assertEq(usdc.balanceOf(taker), takerUsdcBefore + 2000e6);

        // Check status
        VWAPRFQSpot.Trade memory trade = spot.getTrade(tradeId);
        assertEq(uint8(trade.status), uint8(VWAPRFQSpot.Status.Refunded));
    }

    function test_Refund_MakerSellUSDC_BothGetOriginalDeposits() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(false, 2000e6, 1e18);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        bytes32 tradeId = _fillOrder(order, signature, 1e18);

        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);

        vm.warp(block.timestamp + VWAP_WINDOW + REFUND_GRACE + 1);

        spot.refund(tradeId);

        // Both get their deposits back
        assertEq(usdc.balanceOf(maker), makerUsdcBefore + 2000e6);
        assertEq(weth.balanceOf(taker), takerWethBefore + 1e18);
    }

    function test_Refund_AlreadyRefundedReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        bytes32 tradeId = _fillOrder(order, signature, 2000e6);

        vm.warp(block.timestamp + VWAP_WINDOW + REFUND_GRACE + 1);

        // First refund
        spot.refund(tradeId);

        // Try to refund again
        vm.expectRevert(VWAPRFQSpot.TradeNotOpen.selector);
        spot.refund(tradeId);
    }

    // ============ cancelOrderHash() Tests ============

    function test_CancelOrderHash_Success() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes32 orderHash = spot.hashOrder(order);

        vm.expectEmit(true, true, false, false);
        emit Cancelled(maker, orderHash);

        vm.prank(maker);
        spot.cancelOrderHash(orderHash);

        // Verify order is marked as used
        assertTrue(spot.used(maker, orderHash));
    }

    function test_CancelOrderHash_AlreadyUsedReverts() public {
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 1e18, 2000e6);
        bytes32 orderHash = spot.hashOrder(order);

        vm.prank(maker);
        spot.cancelOrderHash(orderHash);

        // Try to cancel again
        vm.prank(maker);
        vm.expectRevert(VWAPRFQSpot.OrderUsed.selector);
        spot.cancelOrderHash(orderHash);
    }

    // ============ Edge Cases & Additional Coverage ============

    function test_Settle_PartialFill_MakerSellETH() public {
        // Maker sells 2 ETH, taker deposits only 3000 USDC
        // At price 2000 USDC/ETH, only 1.5 ETH will be used
        VWAPRFQSpot.Order memory order = _createBasicOrder(true, 2e18, 3000e6);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        uint256 startTime = block.timestamp;
        bytes32 tradeId = _fillOrder(order, signature, 3000e6);

        uint256 endTime = startTime + VWAP_WINDOW;
        oracle.setPrice(startTime, endTime, 2e9); // 2000 USDC/ETH

        vm.warp(endTime + 1);

        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);
        uint256 makerWethBefore = weth.balanceOf(maker);

        spot.settle(tradeId);

        // ethUsed = min(2e18, floor(3000e6 * 1e18 / 2e9)) = min(2e18, 1.5e18) = 1.5e18
        // usdcPaid = floor(1.5e18 * 2e9 / 1e18) = 3000e6
        assertEq(usdc.balanceOf(maker), makerUsdcBefore + 3000e6); // Maker gets all taker's USDC
        assertEq(weth.balanceOf(taker), takerWethBefore + 1.5e18); // Taker gets 1.5 ETH
        assertEq(weth.balanceOf(maker), makerWethBefore + 0.5e18); // Maker gets 0.5 ETH refund
    }

    function test_Settle_PartialFill_MakerSellUSDC() public {
        // Maker sells 4000 USDC, taker deposits 1.5 ETH
        // At price 2000 USDC/ETH, only 3000 USDC will be used
        VWAPRFQSpot.Order memory order = _createBasicOrder(false, 4000e6, 1.5e18);
        bytes memory signature = _signOrder(order, makerPrivateKey);

        uint256 startTime = block.timestamp;
        bytes32 tradeId = _fillOrder(order, signature, 1.5e18);

        uint256 endTime = startTime + VWAP_WINDOW;
        oracle.setPrice(startTime, endTime, 2e9); // 2000 USDC/ETH

        vm.warp(endTime + 1);

        uint256 makerWethBefore = weth.balanceOf(maker);
        uint256 takerUsdcBefore = usdc.balanceOf(taker);
        uint256 makerUsdcBefore = usdc.balanceOf(maker);

        spot.settle(tradeId);

        // usdcUsed = min(4000e6, floor(1.5e18 * 2e9 / 1e18)) = min(4000e6, 3000e6) = 3000e6
        // ethPaid = floor(3000e6 * 1e18 / 2e9) = 1.5e18
        assertEq(weth.balanceOf(maker), makerWethBefore + 1.5e18); // Maker gets all taker's ETH
        assertEq(usdc.balanceOf(taker), takerUsdcBefore + 3000e6); // Taker gets 3000 USDC
        assertEq(usdc.balanceOf(maker), makerUsdcBefore + 1000e6); // Maker gets 1000 USDC refund
    }
}
