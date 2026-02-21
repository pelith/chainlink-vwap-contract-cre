#!/usr/bin/env bash
# Simulate CRE workflow with HTTP trigger payload
# Usage:
#   ./scripts/simulate.sh                              # use default test-payload.json
#   ./scripts/simulate.sh '{"orderId":"1","startTime":1739552400,"endTime":1739595600}'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_DIR="vwap-eth-quote-flow"
TARGET="staging-settings"

if [ $# -ge 1 ]; then
  PAYLOAD="$1"
else
  PAYLOAD="test-payload.json"
fi

echo "=== CRE Workflow Simulate ==="
echo "Workflow: $WORKFLOW_DIR"
echo "Target:   $TARGET"
echo "Payload:  $PAYLOAD"
echo ""

cd "$PROJECT_ROOT"

cre workflow simulate "$WORKFLOW_DIR" \
  --non-interactive \
  --trigger-index 0 \
  --http-payload "$PAYLOAD" \
  --target "$TARGET"
