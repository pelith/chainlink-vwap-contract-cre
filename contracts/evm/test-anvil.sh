#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Test VWAPSettlement on Anvil (local)
# ============================================================
# Usage: ./test-anvil.sh
#
# Starts Anvil, deploys VWAPSettlement, calls onReport with
# test data, then verifies getPrice / isSettled.
# ============================================================

RPC_URL="http://127.0.0.1:8545"
# Anvil default account #0
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# --- Start Anvil in background ---
echo "==> Starting Anvil..."
anvil --silent &
ANVIL_PID=$!
sleep 1

cleanup() {
  echo "==> Stopping Anvil (pid=$ANVIL_PID)"
  kill $ANVIL_PID 2>/dev/null || true
}
trap cleanup EXIT

# --- Deploy ---
echo "==> Deploying VWAPSettlement..."
DEPLOY_OUTPUT=$(forge create \
  src/VWAPSettlement.sol:VWAPSettlement \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --root "$(dirname "$0")" \
  --broadcast \
  2>&1)

ADDR=$(echo "$DEPLOY_OUTPUT" | grep "Deployed to:" | awk '{print $3}')
echo "    Deployed at: $ADDR"

# --- Prepare test data ---
# Simulate what the CRE Forwarder sends to onReport()
#
# orderId   = 42
# startTime = 1700000000  (2023-11-14 22:13:20 UTC)
# endTime   = 1700043200  (2023-11-15 10:13:20 UTC)
# priceE8   = 200523456789  (~$2005.23)
#
# packed = (startTime << 128) | (endTime << 64) | priceE8

ORDER_ID=42
START_TIME=1700000000
END_TIME=1700043200
PRICE_E8=200523456789

echo ""
echo "==> Test data:"
echo "    orderId:   $ORDER_ID"
echo "    startTime: $START_TIME"
echo "    endTime:   $END_TIME"
echo "    priceE8:   $PRICE_E8 (= \$$(echo "scale=8; $PRICE_E8 / 100000000" | bc))"

# Pack: (startTime << 128) | (endTime << 64) | priceE8
# Use cast to compute
PACKED=$(cast --to-uint256 $(python3 -c "print(($START_TIME << 128) | ($END_TIME << 64) | $PRICE_E8)"))

# Encode report = abi.encode(uint256 orderId, uint256 packed)
REPORT=$(cast abi-encode "f(uint256,uint256)" $ORDER_ID $PACKED)

# metadata is empty bytes
METADATA="0x"

echo ""
echo "==> Calling onReport()..."
cast send "$ADDR" \
  "onReport(bytes,bytes)" \
  "$METADATA" "$REPORT" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  > /dev/null

echo "    OK"

# --- Verify ---
echo ""
echo "==> Verifying..."

# isSettled
SETTLED=$(cast call "$ADDR" "isSettled(uint256)(bool)" $ORDER_ID --rpc-url "$RPC_URL")
echo "    isSettled($ORDER_ID): $SETTLED"

# getPrice
PRICE_RESULT=$(cast call "$ADDR" "getPrice(uint256)(uint64,uint64,uint64)" $ORDER_ID --rpc-url "$RPC_URL")
echo "    getPrice($ORDER_ID): $PRICE_RESULT"

# Parse individual values (strip cast's scientific notation annotations like " [1.7e9]")
GOT_START=$(echo "$PRICE_RESULT" | head -1 | awk '{print $1}')
GOT_END=$(echo "$PRICE_RESULT" | sed -n '2p' | awk '{print $1}')
GOT_PRICE=$(echo "$PRICE_RESULT" | sed -n '3p' | awk '{print $1}')

echo ""
echo "==> Assertions:"

PASS=true

if [ "$SETTLED" = "true" ]; then
  echo "    [PASS] isSettled = true"
else
  echo "    [FAIL] isSettled = $SETTLED (expected true)"
  PASS=false
fi

if [ "$GOT_START" = "$START_TIME" ]; then
  echo "    [PASS] startTime = $START_TIME"
else
  echo "    [FAIL] startTime = $GOT_START (expected $START_TIME)"
  PASS=false
fi

if [ "$GOT_END" = "$END_TIME" ]; then
  echo "    [PASS] endTime = $END_TIME"
else
  echo "    [FAIL] endTime = $GOT_END (expected $END_TIME)"
  PASS=false
fi

if [ "$GOT_PRICE" = "$PRICE_E8" ]; then
  echo "    [PASS] priceE8 = $PRICE_E8"
else
  echo "    [FAIL] priceE8 = $GOT_PRICE (expected $PRICE_E8)"
  PASS=false
fi

echo ""
if [ "$PASS" = true ]; then
  echo "============================================================"
  echo "  ALL TESTS PASSED"
  echo "  VWAPSettlement.onReport() decoding is correct."
  echo "============================================================"
else
  echo "============================================================"
  echo "  SOME TESTS FAILED"
  echo "============================================================"
  exit 1
fi
