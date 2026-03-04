#!/usr/bin/env bash
# simulate.sh
#
# Runs CRE workflow simulate and prints the VWAP result.
# No on-chain writes — purely for inspection and debugging.
#
# Arguments:
#   $1  end time — unix timestamp OR human datetime string (e.g. "2025-02-15 15:00")
#       Automatically floored to the hour. Defaults to now.
#       startTime = endTime - 12h.
#
# Usage:
#   ./scripts/simulate.sh
#   ./scripts/simulate.sh "2025-02-15 15:00"
#   ./scripts/simulate.sh 1739595600

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
echo "CRE Workflow Simulate (inspect only, no on-chain write)"
echo "  StartTime: $START_TIME  ($(date -r "$START_TIME" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -d "@$START_TIME" '+%Y-%m-%d %H:%M %Z'))"
echo "  EndTime:   $END_TIME    ($(date -r "$END_TIME"   '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -d "@$END_TIME"   '+%Y-%m-%d %H:%M %Z'))"
echo "============================================================"
echo ""

PAYLOAD="{\"startTime\":$START_TIME,\"endTime\":$END_TIME}"

cd "$PROJECT_ROOT"

cre workflow simulate vwap-eth-quote-flow \
  --non-interactive \
  --trigger-index 0 \
  --http-payload "$PAYLOAD" \
  --target staging-settings
