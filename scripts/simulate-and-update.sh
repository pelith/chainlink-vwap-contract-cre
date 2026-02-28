#!/usr/bin/env bash
# simulate-and-update.sh
#
# Runs CRE workflow simulate, extracts the computed VWAP priceE6,
# and writes it on-chain via ManualVWAPOracle.setPrice().
#
# This bridges CRE off-chain computation with on-chain settlement —
# useful for any environment where the CRE DON cannot write directly
# (local dev, Tenderly VTN, staging without a live forwarder).
#
# Required env vars (loaded from .env automatically):
#   DEPLOYER_PRIVATE_KEY    signs the setPrice transaction
#   MANUAL_ORACLE_ADDRESS   ManualVWAPOracle contract address
#
# Optional env vars:
#   RPC_URL                 target chain RPC (defaults to publicnode Sepolia)
#
# Arguments:
#   $1  end time — unix timestamp OR human datetime string accepted by 'date'
#       Any time is automatically floored to the hour.
#       Defaults to now (floored to current hour).
#
#       startTime is always endTime - 12h.
#
# Usage:
#   ./scripts/simulate-and-update.sh                    # now (floored to hour)
#   ./scripts/simulate-and-update.sh 1739595600         # unix timestamp
#   ./scripts/simulate-and-update.sh "2025-02-15 15:34" # human datetime → 15:00
#   RPC_URL=$TENDERLY_ADMIN_RPC ./scripts/simulate-and-update.sh "2025-02-15 15:34"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env
if [ -f "$REPO_ROOT/.env" ]; then
  # shellcheck disable=SC1090
  set -a; source "$REPO_ROOT/.env"; set +a
fi

RPC_URL="${RPC_URL:-${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}}"
ORACLE_ADDR="${MANUAL_ORACLE_ADDRESS:?MANUAL_ORACLE_ADDRESS not set. Set it in .env or export it.}"
DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"

# Resolve end time from argument (unix or human string) or default to now.
# Then floor to hour and derive start = end - 12h.
_floor_hour() { echo $(( ($1 / 3600) * 3600 )); }
_parse_ts() {
  # Try as integer first, then as date string
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "$1"
  else
    date -j -f "%Y-%m-%d %H:%M" "$1" "+%s" 2>/dev/null \
      || date -d "$1" "+%s" 2>/dev/null \
      || { echo "ERROR: cannot parse time: $1" >&2; exit 1; }
  fi
}

RAW_END="${1:-$(date +%s)}"
END_TIME=$(_floor_hour "$(_parse_ts "$RAW_END")")
START_TIME=$(( END_TIME - 43200 ))

echo "============================================================"
echo "CRE Simulate → On-chain Update"
echo "  RPC:        $RPC_URL"
echo "  Oracle:     $ORACLE_ADDR"
echo "  StartTime:  $START_TIME  ($(date -r "$START_TIME" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -d "@$START_TIME" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo 'n/a'))"
echo "  EndTime:    $END_TIME    ($(date -r "$END_TIME" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -d "@$END_TIME" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo 'n/a'))"
echo "============================================================"
echo ""

# ---- Step 1: Run CRE workflow simulate ----

echo "==> [1/3] Running CRE workflow simulate..."
echo ""

PAYLOAD="{\"startTime\":$START_TIME,\"endTime\":$END_TIME}"

cd "$REPO_ROOT"
SIMULATE_OUTPUT=$(cre workflow simulate vwap-eth-quote-flow \
  --non-interactive \
  --trigger-index 0 \
  --http-payload "$PAYLOAD" \
  --target staging-settings 2>&1)

echo "$SIMULATE_OUTPUT"
echo ""

# ---- Step 2: Parse priceE6 and status ----

echo "==> [2/3] Parsing VWAP result from simulate output..."

# slog format: msg="VWAP result" price=... priceE6=... sourceCount=... status=...
PRICE_E6=$(echo "$SIMULATE_OUTPUT" | grep 'VWAP result' | grep -oE 'priceE6=[0-9]+' | cut -d= -f2 | tail -1)
STATUS=$(echo "$SIMULATE_OUTPUT"   | grep 'VWAP result' | grep -oE 'status=[0-9]+'  | cut -d= -f2 | tail -1)
PRICE=$(echo "$SIMULATE_OUTPUT"    | grep 'VWAP result' | grep -oE 'price=[0-9.e+]+' | head -1 | cut -d= -f2)

if [ -z "${PRICE_E6:-}" ] || [ -z "${STATUS:-}" ]; then
  echo "ERROR: Could not parse VWAP result from simulate output."
  echo "  Check that 'cre workflow simulate' completed successfully."
  exit 1
fi

if [ "$STATUS" != "0" ]; then
  case "$STATUS" in
    1) STATUS_MSG="InsufficientSources" ;;
    2) STATUS_MSG="StaleData" ;;
    3) STATUS_MSG="DeviationError" ;;
    4) STATUS_MSG="DataNotReady" ;;
    *) STATUS_MSG="Unknown" ;;
  esac
  echo "ERROR: VWAP status not OK: $STATUS ($STATUS_MSG) — aborting on-chain write (fail-closed)"
  exit 1
fi

echo "  Status:      $STATUS (OK)"
echo "  Price:       ${PRICE:-n/a} USDC/ETH"
echo "  PriceE6:     $PRICE_E6"
echo ""

# ---- Step 3: Write to oracle on-chain ----

echo "==> [3/3] Writing VWAP to ManualVWAPOracle on-chain..."

cast send "$ORACLE_ADDR" \
  "setPrice(uint256,uint256,uint256)" \
  "$START_TIME" "$END_TIME" "$PRICE_E6" \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY"

echo ""
echo "============================================================"
echo "Done. VWAP price written on-chain."
echo ""
echo "  Oracle:   $ORACLE_ADDR"
echo "  PriceE6:  $PRICE_E6"
echo ""
echo "Verify:"
echo "  cast call $ORACLE_ADDR \\"
echo "    \"getPrice(uint256,uint256)(uint256)\" \\"
echo "    $START_TIME $END_TIME \\"
echo "    --rpc-url $RPC_URL"
echo "============================================================"
