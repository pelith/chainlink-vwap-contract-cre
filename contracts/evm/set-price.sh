#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Inject a price into ManualVWAPOracle
#
# Usage:
#   ./set-price.sh <startTime> <endTime> <priceUSDC>
#
# Arguments:
#   startTime   unix timestamp (seconds)
#   endTime     unix timestamp (seconds)
#   priceUSDC   USDC per 1 ETH, plain number (e.g. 2000)
#
# Example:
#   ./set-price.sh 1740000000 1740043200 2000
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

ORACLE_ADDR="${MANUAL_ORACLE_ADDRESS:-}"
RPC_URL="${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"

if [ -z "${DEPLOYER_PRIVATE_KEY:-}" ]; then
  echo "ERROR: DEPLOYER_PRIVATE_KEY not set"; exit 1
fi

if [ -z "$ORACLE_ADDR" ]; then
  echo "ERROR: MANUAL_ORACLE_ADDRESS not set"
  echo "  Add to .env: MANUAL_ORACLE_ADDRESS=0x..."
  exit 1
fi

if [ "$#" -ne 3 ]; then
  echo "Usage: ./set-price.sh <startTime> <endTime> <priceUSDC>"
  echo "  e.g. ./set-price.sh 1740000000 1740043200 2000"
  exit 1
fi

START_TIME="$1"
END_TIME="$2"
PRICE_USDC="$3"

# Convert to 1e9 precision (price * 1_000_000)
PRICE_SCALED=$(echo "$PRICE_USDC * 1000000" | bc)

echo "Oracle : $ORACLE_ADDR"
echo "Window : $START_TIME → $END_TIME"
echo "Price  : $PRICE_USDC USDC/ETH (scaled: $PRICE_SCALED)"
echo ""

cast send "$ORACLE_ADDR" \
  "setPrice(uint256,uint256,uint256)" \
  "$START_TIME" "$END_TIME" "$PRICE_SCALED" \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY"

echo ""
echo "Verifying..."
RESULT=$(cast call "$ORACLE_ADDR" \
  "getPrice(uint256,uint256)(uint256)" \
  "$START_TIME" "$END_TIME" \
  --rpc-url "$RPC_URL")

echo "getPrice($START_TIME, $END_TIME) = $RESULT"
