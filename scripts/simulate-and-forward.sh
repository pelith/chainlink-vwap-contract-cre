#!/usr/bin/env bash
# simulate-and-forward.sh
#
# Runs CRE workflow simulate, then submits the result through
# MockKeystoneForwarder.report() → oracle.onReport() — the same
# code path as production CRE DON, without real signature verification.
#
# Requires MockKeystoneForwarder to be deployed (already on Sepolia at
# 0x15fC6ae953E024d975e77382eEeC56A9101f9F88, present on any Sepolia fork).
# ManualVWAPOracle must be deployed with forwarder = MockKeystoneForwarder address.
#
# rawReport layout (total >= 109 bytes):
#   [0:45]   forwarder metadata  — version, workflowExecutionId, timestamp, don_id, config_version
#   [45:109] workflow metadata   — workflow_cid, workflow_name, workflow_owner, report_id
#            (becomes `metadata` arg in onReport — ignored by ManualVWAPOracle)
#   [109:]   actual report       — abi.encode(startTime, endTime, priceE6)
#            (becomes `report` arg in onReport — decoded by oracle)
#
# Required env vars:
#   DEPLOYER_PRIVATE_KEY    signs the report() transaction
#   MANUAL_ORACLE_ADDRESS   ManualVWAPOracle deployed with forwarder=MockKeystoneForwarder
#
# Optional env vars:
#   RPC_URL                 target chain RPC (defaults to publicnode Sepolia)
#   FORWARDER_ADDRESS       MockKeystoneForwarder address (defaults to Sepolia mock)
#
# Arguments:
#   $1  end time — unix timestamp OR human datetime string (e.g. "2025-02-15 15:34")
#       Automatically floored to the hour. Defaults to now.
#       startTime = endTime - 12h.
#
# Usage:
#   ./scripts/simulate-and-forward.sh
#   ./scripts/simulate-and-forward.sh "2025-02-15 15:34"
#   RPC_URL=$TENDERLY_ADMIN_RPC ./scripts/simulate-and-forward.sh "2025-02-15 15:34"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  # shellcheck disable=SC1090
  set -a; source "$REPO_ROOT/.env"; set +a
fi

RPC_URL="${RPC_URL:-${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}}"
ORACLE_ADDR="${MANUAL_ORACLE_ADDRESS:?MANUAL_ORACLE_ADDRESS not set}"
DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"
# Default to Sepolia MockKeystoneForwarder (present on any Sepolia fork)
FORWARDER_ADDR="${FORWARDER_ADDRESS:-0x15fC6ae953E024d975e77382eEeC56A9101f9F88}"

_floor_hour() { echo $(( ($1 / 3600) * 3600 )); }
_parse_ts() {
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
echo "CRE Simulate → MockKeystoneForwarder → onReport()"
echo "  RPC:        $RPC_URL"
echo "  Forwarder:  $FORWARDER_ADDR"
echo "  Oracle:     $ORACLE_ADDR"
echo "  StartTime:  $START_TIME  ($(date -r "$START_TIME" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -d "@$START_TIME" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo 'n/a'))"
echo "  EndTime:    $END_TIME    ($(date -r "$END_TIME"   '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -d "@$END_TIME"   '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo 'n/a'))"
echo "============================================================"
echo ""

# ---- Step 1: CRE simulate ----

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

# ---- Step 2: Parse result ----

echo "==> [2/3] Parsing VWAP result..."

PRICE_E6=$(echo "$SIMULATE_OUTPUT" | grep 'VWAP result' | grep -oE 'priceE6=[0-9]+' | cut -d= -f2 | tail -1)
STATUS=$(echo "$SIMULATE_OUTPUT"   | grep 'VWAP result' | grep -oE 'status=[0-9]+'  | cut -d= -f2 | tail -1)
PRICE=$(echo "$SIMULATE_OUTPUT"    | grep 'VWAP result' | grep -oE 'price=[0-9.e+]+' | head -1 | cut -d= -f2)

if [ -z "${PRICE_E6:-}" ] || [ -z "${STATUS:-}" ]; then
  echo "ERROR: Could not parse VWAP result from simulate output."
  exit 1
fi

if [ "$STATUS" != "0" ]; then
  case "$STATUS" in
    1) MSG="InsufficientSources" ;; 2) MSG="StaleData" ;;
    3) MSG="DeviationError" ;;     4) MSG="DataNotReady" ;;
    *) MSG="Unknown" ;;
  esac
  echo "ERROR: VWAP status $STATUS ($MSG) — fail-closed, aborting"
  exit 1
fi

echo "  Status:   $STATUS (OK)"
echo "  Price:    ${PRICE:-n/a} USDC/ETH"
echo "  PriceE6:  $PRICE_E6"
echo ""

# ---- Step 3: Construct rawReport and call MockKeystoneForwarder.report() ----
#
# rawReport layout:
#   [0:45]   = 45 zero bytes  (forwarder metadata prefix — version/executionId/etc.)
#   [45:109] = 64 zero bytes  (workflow metadata — passed as `metadata` to onReport, ignored)
#   [109:]   = abi.encode(uint256 startTime, uint256 endTime, uint256 priceE6)

echo "==> [3/3] Constructing rawReport and calling MockKeystoneForwarder.report()..."

# abi.encode(startTime, endTime, priceE6) → 96 bytes (192 hex chars), strip leading 0x
ENCODED_REPORT=$(cast abi-encode "f(uint256,uint256,uint256)" "$START_TIME" "$END_TIME" "$PRICE_E6")
REPORT_HEX="${ENCODED_REPORT#0x}"

# 109 zero bytes = 218 hex chars
METADATA_HEX=$(printf '%0218d' 0)

RAW_REPORT="0x${METADATA_HEX}${REPORT_HEX}"

echo "  rawReport: ${#RAW_REPORT} hex chars = $(( (${#RAW_REPORT} - 2) / 2 )) bytes"
echo ""

cast send "$FORWARDER_ADDR" \
  "report(address,bytes,bytes,bytes[])" \
  "$ORACLE_ADDR" \
  "$RAW_REPORT" \
  "0x" \
  "[]" \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY"

echo ""
echo "============================================================"
echo "Done. Report routed through MockKeystoneForwarder → onReport()."
echo ""
echo "  Forwarder: $FORWARDER_ADDR"
echo "  Oracle:    $ORACLE_ADDR"
echo "  PriceE6:   $PRICE_E6"
echo ""
echo "Verify:"
echo "  cast call $ORACLE_ADDR \\"
echo "    \"getPrice(uint256,uint256)(uint256)\" \\"
echo "    $START_TIME $END_TIME \\"
echo "    --rpc-url $RPC_URL"
echo "============================================================"
