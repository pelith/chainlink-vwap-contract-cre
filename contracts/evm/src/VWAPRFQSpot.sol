// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVWAPOracle} from "./IVWAPOracle.sol";

/// @title VWAPRFQSpot
/// @notice Delayed settlement spot exchange using VWAP pricing
/// @dev EIP-712 compliant order signing, supports partial fills
contract VWAPRFQSpot is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ============ Constants ============

    /// @notice VWAP calculation window (12 hours)
    uint256 public constant VWAP_WINDOW = 12 hours;

    /// @notice Grace period after which refund becomes available
    uint256 public immutable REFUND_GRACE;

    /// @notice USDC token address
    IERC20 public immutable USDC;

    /// @notice WETH token address
    IERC20 public immutable WETH;

    /// @notice VWAP oracle address
    IVWAPOracle public immutable oracle;

    // ============ EIP-712 ============

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,bool makerIsSellETH,uint256 amountIn,uint256 minAmountOut,int32 deltaBps,uint256 salt,uint256 deadline)"
    );

    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;

    // ============ Types ============

    /// @notice Order status
    enum Status {
        Open,
        Settled,
        Refunded
    }

    /// @notice Maker order structure (for EIP-712 signing)
    struct Order {
        address maker;
        bool makerIsSellETH;    // true: maker sells WETH for USDC; false: maker sells USDC for WETH
        uint256 amountIn;       // amount of token maker sells (maker deposit)
        uint256 minAmountOut;   // minimum amount taker must deposit (opposite token)
        int32 deltaBps;         // signed bps applied to P_vwap
        uint256 salt;           // arbitrary number for uniqueness
        uint256 deadline;       // order expiry timestamp
    }

    /// @notice On-chain trade record
    struct Trade {
        address maker;
        address taker;
        bool makerIsSellETH;
        uint256 makerAmountIn;
        uint256 takerDeposit;
        int32 deltaBps;
        uint64 startTime;
        uint64 endTime;
        Status status;
    }

    // ============ State ============

    /// @notice Tracks used order hashes (filled or cancelled)
    mapping(address => mapping(bytes32 => bool)) public used;

    /// @notice Trade records indexed by tradeId (= orderHash)
    mapping(bytes32 => Trade) public trades;

    // ============ Custom Errors ============

    error ExpiredOrder();
    error BadSignature();
    error OrderUsed();
    error DeltaInvalid();
    error TakerTooSmall();
    error TradeNotOpen();
    error NotMatured();
    error RefundNotAvailable();
    error TooLateToSettle();

    // ============ Events ============

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

    // ============ Constructor ============

    /// @notice Deploy the VWAP RFQ Spot contract
    /// @param _usdc USDC token address
    /// @param _weth WETH token address
    /// @param _oracle VWAP oracle address
    /// @param _refundGrace Grace period for refund (suggested: 7 days)
    constructor(
        address _usdc,
        address _weth,
        address _oracle,
        uint256 _refundGrace
    ) {
        USDC = IERC20(_usdc);
        WETH = IERC20(_weth);
        oracle = IVWAPOracle(_oracle);
        REFUND_GRACE = _refundGrace;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("VWAP-RFQ-Spot")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    // ============ External Functions ============

    /// @notice Fill a maker order
    /// @param order The maker's signed order
    /// @param signature EIP-712 signature of the order
    /// @param takerAmountIn Amount the taker is depositing
    /// @return tradeId The trade identifier (= orderHash)
    function fill(
        Order calldata order,
        bytes calldata signature,
        uint256 takerAmountIn
    ) external nonReentrant returns (bytes32 tradeId) {
        // 1. Check deadline
        if (block.timestamp > order.deadline) revert ExpiredOrder();

        // 2. Check delta validity
        if (int256(10000) + int256(order.deltaBps) <= 0) revert DeltaInvalid();

        // 3. Check taker minimum
        if (takerAmountIn < order.minAmountOut) revert TakerTooSmall();

        // 4. Calculate order hash
        bytes32 orderHash = _hashOrder(order);

        // 5. Verify signature
        address signer = ECDSA.recover(orderHash, signature);
        if (signer != order.maker) revert BadSignature();

        // 6. Check not already used
        if (used[order.maker][orderHash]) revert OrderUsed();

        // 7. Mark as used BEFORE transfers (CEI pattern)
        used[order.maker][orderHash] = true;

        // 8. Lock funds
        if (order.makerIsSellETH) {
            // Maker deposits WETH, taker deposits USDC
            WETH.safeTransferFrom(order.maker, address(this), order.amountIn);
            USDC.safeTransferFrom(msg.sender, address(this), takerAmountIn);
        } else {
            // Maker deposits USDC, taker deposits WETH
            USDC.safeTransferFrom(order.maker, address(this), order.amountIn);
            WETH.safeTransferFrom(msg.sender, address(this), takerAmountIn);
        }

        // 9. Create trade record
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = startTime + uint64(VWAP_WINDOW);

        trades[orderHash] = Trade({
            maker: order.maker,
            taker: msg.sender,
            makerIsSellETH: order.makerIsSellETH,
            makerAmountIn: order.amountIn,
            takerDeposit: takerAmountIn,
            deltaBps: order.deltaBps,
            startTime: startTime,
            endTime: endTime,
            status: Status.Open
        });

        tradeId = orderHash;

        emit Filled(
            order.maker,
            msg.sender,
            orderHash,
            startTime,
            endTime,
            order.amountIn,
            takerAmountIn,
            order.makerIsSellETH,
            order.deltaBps
        );
    }

    /// @notice Settle a matured trade using VWAP pricing
    /// @param tradeId The trade identifier
    function settle(bytes32 tradeId) external nonReentrant {
        Trade storage trade = trades[tradeId];

        // 1. Check status
        if (trade.status != Status.Open) revert TradeNotOpen();

        // 2. Check matured
        if (block.timestamp < trade.endTime) revert NotMatured();

        // 3. Check not past refund grace (force refund instead)
        if (block.timestamp >= trade.endTime + REFUND_GRACE) revert TooLateToSettle();

        // 4. Get VWAP from oracle (may revert if data unavailable)
        uint256 usdcPerEth = oracle.getPrice(trade.startTime, trade.endTime);

        // 5. Calculate adjusted price
        // P_adj = P_vwap * (10000 + deltaBps) / 10000
        uint256 deltaMult = uint256(int256(10000) + int256(trade.deltaBps));
        uint256 adjustedPrice = Math.mulDiv(usdcPerEth, deltaMult, 10000);

        // 6. Calculate exchange amounts
        uint256 makerPayout;
        uint256 takerPayout;
        uint256 makerRefund;
        uint256 takerRefund;

        if (trade.makerIsSellETH) {
            // Maker sells WETH for USDC
            // makerDeposit = makerAmountIn (WETH)
            // takerDeposit = takerDeposit (USDC)
            
            uint256 makerEth = trade.makerAmountIn;
            uint256 takerUsdc = trade.takerDeposit;

            // ethUsed = min(makerEth, floor(takerUsdc * 1e18 / P_adj))
            uint256 maxEthFromUsdc = Math.mulDiv(takerUsdc, 1e18, adjustedPrice);
            uint256 ethUsed = makerEth < maxEthFromUsdc ? makerEth : maxEthFromUsdc;

            // usdcPaid = floor(ethUsed * P_adj / 1e18)
            uint256 usdcPaid = Math.mulDiv(ethUsed, adjustedPrice, 1e18);

            // Maker receives USDC, taker receives WETH
            makerPayout = usdcPaid;
            takerPayout = ethUsed;
            makerRefund = makerEth - ethUsed;
            takerRefund = takerUsdc - usdcPaid;

            // Transfer payouts
            if (makerPayout > 0) USDC.safeTransfer(trade.maker, makerPayout);
            if (takerPayout > 0) WETH.safeTransfer(trade.taker, takerPayout);
            // Transfer refunds
            if (makerRefund > 0) WETH.safeTransfer(trade.maker, makerRefund);
            if (takerRefund > 0) USDC.safeTransfer(trade.taker, takerRefund);
        } else {
            // Maker sells USDC for WETH
            // makerDeposit = makerAmountIn (USDC)
            // takerDeposit = takerDeposit (WETH)

            uint256 makerUsdc = trade.makerAmountIn;
            uint256 takerEth = trade.takerDeposit;

            // usdcUsed = min(makerUsdc, floor(takerEth * P_adj / 1e18))
            uint256 maxUsdcFromEth = Math.mulDiv(takerEth, adjustedPrice, 1e18);
            uint256 usdcUsed = makerUsdc < maxUsdcFromEth ? makerUsdc : maxUsdcFromEth;

            // ethPaid = floor(usdcUsed * 1e18 / P_adj)
            uint256 ethPaid = Math.mulDiv(usdcUsed, 1e18, adjustedPrice);

            // Maker receives WETH, taker receives USDC
            makerPayout = ethPaid;
            takerPayout = usdcUsed;
            makerRefund = makerUsdc - usdcUsed;
            takerRefund = takerEth - ethPaid;

            // Transfer payouts
            if (makerPayout > 0) WETH.safeTransfer(trade.maker, makerPayout);
            if (takerPayout > 0) USDC.safeTransfer(trade.taker, takerPayout);
            // Transfer refunds
            if (makerRefund > 0) USDC.safeTransfer(trade.maker, makerRefund);
            if (takerRefund > 0) WETH.safeTransfer(trade.taker, takerRefund);
        }

        // 7. Update status
        trade.status = Status.Settled;

        emit Settled(
            tradeId,
            usdcPerEth,
            adjustedPrice,
            makerPayout,
            takerPayout,
            makerRefund,
            takerRefund
        );
    }

    /// @notice Refund a trade after grace period (when oracle fails or settlement timeout)
    /// @param tradeId The trade identifier
    function refund(bytes32 tradeId) external nonReentrant {
        Trade storage trade = trades[tradeId];

        // 1. Check status
        if (trade.status != Status.Open) revert TradeNotOpen();

        // 2. Check past grace period
        if (block.timestamp < trade.endTime + REFUND_GRACE) revert RefundNotAvailable();

        // 3. Refund both parties their original deposits
        uint256 makerRefund = trade.makerAmountIn;
        uint256 takerRefund = trade.takerDeposit;

        if (trade.makerIsSellETH) {
            // Maker deposited WETH, taker deposited USDC
            if (makerRefund > 0) WETH.safeTransfer(trade.maker, makerRefund);
            if (takerRefund > 0) USDC.safeTransfer(trade.taker, takerRefund);
        } else {
            // Maker deposited USDC, taker deposited WETH
            if (makerRefund > 0) USDC.safeTransfer(trade.maker, makerRefund);
            if (takerRefund > 0) WETH.safeTransfer(trade.taker, takerRefund);
        }

        // 4. Update status
        trade.status = Status.Refunded;

        emit Refunded(tradeId, makerRefund, takerRefund);
    }

    /// @notice Cancel an unfilled order by its hash
    /// @dev Does not reveal order details on-chain
    /// @param orderHash The EIP-712 hash of the order to cancel
    function cancelOrderHash(bytes32 orderHash) external nonReentrant {
        // Check not already used
        if (used[msg.sender][orderHash]) revert OrderUsed();

        // Mark as used
        used[msg.sender][orderHash] = true;

        emit Cancelled(msg.sender, orderHash);
    }

    // ============ View Functions ============

    /// @notice Get the EIP-712 hash of an order
    /// @param order The order to hash
    /// @return The EIP-712 typed data hash
    function hashOrder(Order calldata order) external view returns (bytes32) {
        return _hashOrder(order);
    }

    /// @notice Get trade details
    /// @param tradeId The trade identifier
    /// @return The trade struct
    function getTrade(bytes32 tradeId) external view returns (Trade memory) {
        return trades[tradeId];
    }

    // ============ Internal Functions ============

    /// @dev Calculate EIP-712 typed data hash for an order
    function _hashOrder(Order calldata order) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.maker,
                order.makerIsSellETH,
                order.amountIn,
                order.minAmountOut,
                order.deltaBps,
                order.salt,
                order.deadline
            )
        );

        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                structHash
            )
        );
    }
}
