#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Deploy VWAP RFQ Spot contracts to Sepolia
#
# Required env vars (set in .env or export manually):
#   DEPLOYER_PRIVATE_KEY   Sepolia funded deployer key (0x...)
#
# Required for ChainlinkVWAPAdapter mode:
#   FORWARDER_ADDRESS      Chainlink CRE Forwarder address
#
# Optional:
#   ORACLE_MODE            "chainlink" (default) | "manual"
#                          manual = deploy ManualVWAPOracle (for testing)
#   SEPOLIA_RPC_URL        defaults to publicnode
#   USDC_ADDRESS           defaults to Circle Sepolia USDC
#   WETH_ADDRESS           defaults to canonical Sepolia WETH
#   REFUND_GRACE           grace period in seconds (default: 604800 = 7 days)
#
# Usage:
#   source ../../.env          # load DEPLOYER_PRIVATE_KEY etc.
#   ORACLE_MODE=manual ./deploy.sh          # test with ManualVWAPOracle
#   ORACLE_MODE=chainlink ./deploy.sh       # production with CRE adapter
# ============================================================

# Load .env from repo root if it exists
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -f "$REPO_ROOT/.env" ]; then
  # shellcheck disable=SC1090
  set -a; source "$REPO_ROOT/.env"; set +a
fi

RPC_URL="${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
USDC_ADDRESS="${USDC_ADDRESS:-0xFA0bd2B4d6D629AdF683e4DCA310c562bCD98E4E}"
WETH_ADDRESS="${WETH_ADDRESS:-0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14}"
REFUND_GRACE="${REFUND_GRACE:-604800}"
ORACLE_MODE="${ORACLE_MODE:-chainlink}"

# ---- Validation ----

if [ -z "${DEPLOYER_PRIVATE_KEY:-}" ]; then
  echo "ERROR: DEPLOYER_PRIVATE_KEY not set"
  echo "  Add it to .env or: export DEPLOYER_PRIVATE_KEY=0x..."
  exit 1
fi

if [ "$ORACLE_MODE" = "chainlink" ] && [ -z "${FORWARDER_ADDRESS:-}" ]; then
  echo "ERROR: FORWARDER_ADDRESS not set (required for ORACLE_MODE=chainlink)"
  echo "  export FORWARDER_ADDRESS=0x..."
  exit 1
fi

echo "============================================================"
echo "Deploying to Sepolia"
echo "  Mode:          $ORACLE_MODE"
echo "  RPC:           $RPC_URL"
echo "  USDC:          $USDC_ADDRESS"
echo "  WETH:          $WETH_ADDRESS"
echo "  Refund grace:  ${REFUND_GRACE}s"
echo "============================================================"
echo ""

# ---- Step 1: Deploy Oracle ----

if [ "$ORACLE_MODE" = "manual" ]; then
  # Derive deployer address from private key
  DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")

  MANUAL_FORWARDER="${FORWARDER_ADDRESS:-}"
  if [ -n "$MANUAL_FORWARDER" ]; then
    echo "==> [1/2] Deploying ManualVWAPOracle (owner: $DEPLOYER_ADDR, forwarder: $MANUAL_FORWARDER)..."
  else
    MANUAL_FORWARDER="0x0000000000000000000000000000000000000000"
    echo "==> [1/2] Deploying ManualVWAPOracle (owner: $DEPLOYER_ADDR, forwarder: open/none)..."
  fi

  ORACLE_OUTPUT=$(forge create \
    src/ManualVWAPOracle.sol:ManualVWAPOracle \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --root "$SCRIPT_DIR" \
    --broadcast \
    --constructor-args "$DEPLOYER_ADDR" "$MANUAL_FORWARDER" \
    2>&1)

  echo "$ORACLE_OUTPUT"
  ORACLE_ADDR=$(echo "$ORACLE_OUTPUT" | grep "Deployed to:" | awk '{print $3}')

  if [ -z "$ORACLE_ADDR" ]; then
    echo "ERROR: Failed to extract ManualVWAPOracle address"
    exit 1
  fi

  echo ""
  echo "  ManualVWAPOracle deployed at: $ORACLE_ADDR"

else
  echo "==> [1/2] Deploying ChainlinkVWAPAdapter (forwarder: $FORWARDER_ADDRESS)..."

  ORACLE_OUTPUT=$(forge create \
    src/ChainlinkVWAPAdapter.sol:ChainlinkVWAPAdapter \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --root "$SCRIPT_DIR" \
    --broadcast \
    --constructor-args "$FORWARDER_ADDRESS" \
    2>&1)

  echo "$ORACLE_OUTPUT"
  ORACLE_ADDR=$(echo "$ORACLE_OUTPUT" | grep "Deployed to:" | awk '{print $3}')

  if [ -z "$ORACLE_ADDR" ]; then
    echo "ERROR: Failed to extract ChainlinkVWAPAdapter address"
    exit 1
  fi

  echo ""
  echo "  ChainlinkVWAPAdapter deployed at: $ORACLE_ADDR"
fi

echo ""

# ---- Step 2: Deploy VWAPRFQSpot ----

echo "==> [2/2] Deploying VWAPRFQSpot..."

SPOT_OUTPUT=$(forge create \
  src/VWAPRFQSpot.sol:VWAPRFQSpot \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --root "$SCRIPT_DIR" \
  --broadcast \
  --constructor-args "$USDC_ADDRESS" "$WETH_ADDRESS" "$ORACLE_ADDR" "$REFUND_GRACE" \
  2>&1)

echo "$SPOT_OUTPUT"

SPOT_ADDR=$(echo "$SPOT_OUTPUT" | grep "Deployed to:" | awk '{print $3}')

if [ -z "$SPOT_ADDR" ]; then
  echo "ERROR: Failed to extract VWAPRFQSpot address"
  exit 1
fi

echo ""
echo "  VWAPRFQSpot deployed at: $SPOT_ADDR"
echo ""

echo ""
echo "============================================================"
echo "Deployment complete!"
echo ""
if [ "$ORACLE_MODE" = "manual" ]; then
  echo "  ManualVWAPOracle : $ORACLE_ADDR"
else
  echo "  ChainlinkVWAPAdapter : $ORACLE_ADDR"
fi
echo "  VWAPRFQSpot          : $SPOT_ADDR"
echo ""

if [ "$ORACLE_MODE" = "manual" ]; then
  echo "Manual oracle usage:"
  echo "  # Inject price: 2000 USDC/ETH for a time window"
  echo "  cast send $ORACLE_ADDR \\"
  echo "    \"setPrice(uint256,uint256,uint256)\" \\"
  echo "    <startTime> <endTime> 2000000000 \\"
  echo "    --rpc-url $RPC_URL --private-key \$DEPLOYER_PRIVATE_KEY"
  echo ""
  echo "  # Settle trade after price is set:"
  echo "  cast send $SPOT_ADDR \"settle(bytes32)\" <tradeId> \\"
  echo "    --rpc-url $RPC_URL --private-key \$DEPLOYER_PRIVATE_KEY"
else
  echo "Next steps:"
  echo "  1. Update workflow config: reserveManagerAddress = $ORACLE_ADDR"
  echo "  2. cre workflow deploy --target staging-settings"
  echo "  3. Trigger: go run ./cmd/trigger/ <orderId> <startTime> <endTime>"
fi
echo "============================================================"
