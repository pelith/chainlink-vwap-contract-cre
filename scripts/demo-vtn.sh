#!/usr/bin/env bash
# demo-vtn.sh
#
# Creates 4 orders on Tenderly VTN in different settlement states for demo / grant submission.
# Deploys contracts fresh on the VTN at startup, then prints addresses to update .env.
#
# Final states (frozen at T0+182H, REFUND_GRACE = 7 days):
#   A  Settled           — filled T0,      oracle price set, settled at T0+13H
#   B  Ready to Settle   — filled T0+13H,  oracle price set, not settled
#   C  Ready to Refund   — filled T0+1H,   no oracle price, grace expired at T0+181H
#   D  Pending           — filled T0+169H, no oracle price, endTime T0+181H just passed
#
# Timeline (all times in seconds from T0, T0 = next exact hour boundary):
#
#   T0            (+0H)    fill A    startA=T0,     endA=T0+12H
#   T0+3600       (+1H)    fill C    startC=T0+1H,  endC=T0+13H
#   T0+46800      (+13H)   advance → setPrice(A), settle(A), fill B
#                            startB=T0+13H, endB=T0+25H
#   T0+608400     (+169H)  advance → fill D
#                            startD=T0+169H, endD=T0+181H
#   T0+655200     (+182H)  advance → setPrice(B) ← final frozen state
#
# At T0+655200 (T0+182H):
#   A: Settled ✓
#   B: endTime T0+25H passed, oracle price set, grace T0+193H not expired → Ready to Settle ✓
#   C: endTime T0+13H passed, no price, grace T0+181H expired (1H ago) → Ready to Refund ✓
#   D: endTime T0+181H passed (1H ago), no price, grace T0+349H not expired → Pending ✓
#
# Oracle key isolation (T0 = exact hour, all fill times are exact hours):
#   A: keccak(T0+0H,   T0+12H)  ← setPrice → A settles
#   C: keccak(T0+1H,   T0+13H)  ← no setPrice → C refunds only
#   B: keccak(T0+13H,  T0+25H)  ← setPrice → B ready to settle from UI
#   D: keccak(T0+169H, T0+181H) ← no setPrice → D pending
#
# Required env:
#   TENDERLY_ADMIN_RPC       VTN admin RPC endpoint (supports evm_setNextBlockTimestamp)
#   DEPLOYER_PRIVATE_KEY     Funded deployer on VTN
#
# Optional:
#   FORWARDER_ADDRESS        MockKeystoneForwarder address (default: Sepolia 0x15fC...F88)
#
# Usage:
#   ./scripts/demo-vtn.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

RPC="${TENDERLY_ADMIN_RPC:?TENDERLY_ADMIN_RPC not set}"
KEY="${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"
FORWARDER="${FORWARDER_ADDRESS:-0x15fC6ae953E024d975e77382eEeC56A9101f9F88}"
DEPLOYER=$(cast wallet address --private-key "$KEY")

# Read fork block timestamp BEFORE any transaction — Tenderly resets block
# timestamps to wall-clock time on each mined block.
FORK_NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
echo "Fork block timestamp: $FORK_NOW ($(date -r "$FORK_NOW" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -d "@$FORK_NOW" '+%Y-%m-%d %H:%M %Z'))"
echo ""

# ─── Deploy contracts on VTN ──────────────────────────────────────────────────

echo "============================================================"
echo "  Deploying contracts to VTN..."
echo "  RPC:      $RPC"
echo "  Deployer: $DEPLOYER"
echo "============================================================"
echo ""

DEPLOY_OUTPUT=$(RPC_URL="$RPC" \
  ORACLE_MODE=manual \
  FORWARDER_ADDRESS="$FORWARDER" \
  bash "$SCRIPT_DIR/../contracts/evm/deploy.sh" 2>&1)
echo "$DEPLOY_OUTPUT"
echo ""

ORACLE=$(echo "$DEPLOY_OUTPUT" | grep "ManualVWAPOracle deployed at:" | awk '{print $NF}')
SPOT=$(echo "$DEPLOY_OUTPUT"   | grep "VWAPRFQSpot deployed at:"      | awk '{print $NF}')

if [ -z "$ORACLE" ] || [ -z "$SPOT" ]; then
  echo "ERROR: Failed to parse deployed contract addresses from deploy.sh output."
  exit 1
fi

echo "  => ManualVWAPOracle : $ORACLE"
echo "  => VWAPRFQSpot      : $SPOT"
echo ""

REFUND_GRACE=604800       # 7 days — matches deployed contract
WETH_AMOUNT="1000000000000000000"   # 1 WETH (18 decimals)
USDC_AMOUNT="2000000000"            # 2000 USDC (6 decimals)

# ─── Helpers ──────────────────────────────────────────────────────────────────

set_time() {
  local hex
  hex=$(printf '0x%x' "$1")
  curl -s -X POST "$RPC" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"evm_setNextBlockTimestamp\",\"params\":[\"$hex\"],\"id\":1}" \
    > /dev/null
}

get_now() {
  printf '%d' "$(cast block latest --field timestamp --rpc-url "$RPC")"
}

# Sign EIP-712 order hash and call fill(). Returns tradeId (= orderHash).
fill_order() {
  local spot=$1 order=$2 taker_amount=$3
  local hash sig
  hash=$(cast call "$spot" \
    "hashOrder((address,bool,uint256,uint256,int32,uint256,uint256))(bytes32)" \
    "$order" --rpc-url "$RPC")
  # --no-hash: raw ECDSA on the 32-byte digest — matches OZ ECDSA.recover(hash, sig) ✓
  sig=$(cast wallet sign --private-key "$KEY" --no-hash "$hash")
  cast send "$spot" \
    "fill((address,bool,uint256,uint256,int32,uint256,uint256),bytes,uint256)" \
    "$order" "$sig" "$taker_amount" \
    --rpc-url "$RPC" --private-key "$KEY" --quiet
  echo "$hash"
}

fmt_time() {
  date -r "$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
    || date -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
    || echo "ts=$1"
}

# roundUpToHour — mirrors ManualVWAPOracle._roundUpToHour()
roundup_hour() { echo $(( ($1 + 3599) / 3600 * 3600 )); }

# Read trade's actual endTime from contract, round up to hour → use as simulate endTime.
# oracle.getPrice() also roundsUp internally, so keys will match.
sim_end_for_trade() {
  local tradeId=$1
  local end
  # Extract the last 10-digit unix timestamp from the trades() tuple output.
  # cast may output annotations like [1e18] or split fields across lines.
  end=$(cast call "$SPOT" \
    "trades(bytes32)(address,bool,uint8,uint256,uint256,int32,uint256,uint256)" \
    "$tradeId" --rpc-url "$RPC" \
    | grep -oE '[0-9]{10}' | tail -1)
  roundup_hour "$end"
}

# ─── Step 1: Resolve token addresses from deployed contract ───────────────────

echo "============================================================"
echo "  VTN Demo — VWAP-RFQ-Spot (4 order states)"
echo "  RPC:          $RPC"
echo "  Deployer:     $DEPLOYER"
echo "  VWAPRFQSpot:  $SPOT"
echo "  Oracle:       $ORACLE"
echo "  REFUND_GRACE: ${REFUND_GRACE}s (7 days)"
echo "============================================================"
echo ""
echo "==> [1/6] Resolving token addresses from contract..."

USDC=$(cast call "$SPOT" "USDC()(address)" --rpc-url "$RPC")
WETH=$(cast call "$SPOT" "WETH()(address)" --rpc-url "$RPC")

echo "  USDC: $USDC"
echo "  WETH: $WETH"
echo ""

# ─── Step 2: Lock in T0 from VTN fork time BEFORE any cast send ──────────────
T0=$(( (FORK_NOW / 3600 + 1) * 3600 ))

# Derived timestamps (all multiples of 3600 → exact hours)
TA=$T0                               # A fills at T0+0H
TC=$(( T0 + 3600 ))                  # C fills at T0+1H
T_SETTLE=$(( T0 + 46800 ))           # T0+13H: settle A, fill B
TB=$T_SETTLE
TD=$(( T0 + 608400 ))                # T0+169H: fill D  (= T0+1H+REFUND_GRACE)
T_FINAL=$(( T0 + 655200 ))           # T0+182H: setPrice(B), freeze (= T0+2H+12H+REFUND_GRACE)

DEADLINE=$(( T0 + 30 * 86400 ))      # +30 days, valid for all orders

# Set timestamp BEFORE any cast send so all subsequent blocks use the fork's time
set_time "$T0"

# ─── Step 3: Fund + approve ───────────────────────────────────────────────────

echo "==> [2/6] Funding tokens via tenderly_setErc20Balance and approving VWAPRFQSpot..."

MAX="115792089237316195423570985008687907853269984665640564039457584007913129639935"

set_erc20_balance() {
  local token=$1 holder=$2 amount_hex=$3
  curl -s -X POST "$RPC" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"tenderly_setErc20Balance\",\"params\":[\"$token\",\"$holder\",\"$amount_hex\"],\"id\":1}" \
    > /dev/null
}

set_erc20_balance "$USDC" "$DEPLOYER" "0x4A817C800"           # 20,000 USDC (6 decimals)
set_erc20_balance "$WETH" "$DEPLOYER" "0x4563918244F40000"    # 5 WETH (18 decimals)

cast send "$USDC" "approve(address,uint256)" "$SPOT" "$MAX" \
  --rpc-url "$RPC" --private-key "$KEY" --quiet
cast send "$WETH" "approve(address,uint256)" "$SPOT" "$MAX" \
  --rpc-url "$RPC" --private-key "$KEY" --quiet

echo "  Funded 20,000 USDC + 5 WETH, approved VWAPRFQSpot"
echo ""
echo "==> [3/6] Timeline"
echo "  T0      = $T0  ($(fmt_time $T0))  ← fill A"
echo "  T0+1H   = $(fmt_time $TC)    ← fill C"
echo "  T0+13H  = $(fmt_time $T_SETTLE)   ← settle A, fill B"
echo "  T0+169H = $(fmt_time $TD)   ← fill D"
echo "  T0+182H = $(fmt_time $T_FINAL)   ← frozen state"
echo ""

# ─── Step 4: Fill A at T0 ────────────────────────────────────────────────────

echo "==> [4/6] T0+0H: fill A..."

ORDER_A="($DEPLOYER,true,$WETH_AMOUNT,1800000000,0,1,$DEADLINE)"
TRADE_ID_A=$(fill_order "$SPOT" "$ORDER_A" "$USDC_AMOUNT")
echo "  tradeId A: $TRADE_ID_A"
echo "  endTime A: $(fmt_time $(( TA + 43200 )))"
echo ""

# ─── Step 5: T0+1H: fill C ───────────────────────────────────────────────────

echo "==> [5/6] T0+1H: fill C..."
set_time "$TC"

ORDER_C="($DEPLOYER,true,$WETH_AMOUNT,1800000000,0,2,$DEADLINE)"
TRADE_ID_C=$(fill_order "$SPOT" "$ORDER_C" "$USDC_AMOUNT")
echo "  tradeId C: $TRADE_ID_C"
echo "  endTime C:   $(fmt_time $(( TC + 43200 )))"
echo "  C grace exp: $(fmt_time $(( TC + 43200 + REFUND_GRACE )))"
echo ""

# ─── Step 6: T0+13H: setPrice(A), settle(A), fill B ─────────────────────────

echo "==> [6/6] T0+13H: simulate(A) → onReport → settle(A) → fill B..."
set_time "$T_SETTLE"

# CRE simulate → MockKeystoneForwarder → onReport() using trade A's actual endTime (rounded up)
SIM_END_A=$(sim_end_for_trade "$TRADE_ID_A")
RPC_URL="$RPC" MANUAL_ORACLE_ADDRESS="$ORACLE" bash "$SCRIPT_DIR/simulate-and-forward.sh" "$SIM_END_A"

cast send "$SPOT" "settle(bytes32)" "$TRADE_ID_A" \
  --rpc-url "$RPC" --private-key "$KEY" --quiet
echo "  Order A: Settled ✓"

ORDER_B="($DEPLOYER,true,$WETH_AMOUNT,1800000000,0,3,$DEADLINE)"
TRADE_ID_B=$(fill_order "$SPOT" "$ORDER_B" "$USDC_AMOUNT")
echo "  tradeId B: $TRADE_ID_B"
echo "  endTime B: $(fmt_time $(( TB + 43200 )))"
echo ""

# ─── Step 7: T0+169H: fill D ─────────────────────────────────────────────────

echo "==> T0+169H: fill D..."
set_time "$TD"

ORDER_D="($DEPLOYER,true,$WETH_AMOUNT,1800000000,0,4,$DEADLINE)"
TRADE_ID_D=$(fill_order "$SPOT" "$ORDER_D" "$USDC_AMOUNT")
echo "  tradeId D: $TRADE_ID_D"
echo "  endTime D: $(fmt_time $(( TD + 43200 )))  (= C grace expiry)"
echo ""

# ─── Final: T0+182H: setPrice(B), freeze ─────────────────────────────────────

echo "==> Advancing to T0+182H (final frozen state)..."
set_time "$T_FINAL"

# CRE simulate → MockKeystoneForwarder → onReport() using trade B's actual endTime (rounded up)
SIM_END_B=$(sim_end_for_trade "$TRADE_ID_B")
RPC_URL="$RPC" MANUAL_ORACLE_ADDRESS="$ORACLE" bash "$SCRIPT_DIR/simulate-and-forward.sh" "$SIM_END_B"
echo "  Oracle price set for B via CRE simulate (NOT settling — stays Ready to Settle)"
echo ""

# ─── Summary ──────────────────────────────────────────────────────────────────

echo "============================================================"
echo "  CONTRACTS"
echo "    USDC:             $USDC"
echo "    WETH:             $WETH"
echo "    ManualVWAPOracle: $ORACLE"
echo "    VWAPRFQSpot:      $SPOT"
echo ""
echo "  FROZEN STATE at $(fmt_time $T_FINAL)"
echo ""
echo "    [Settled]          tradeId A: $TRADE_ID_A"
echo "    [Ready to Settle]  tradeId B: $TRADE_ID_B"
echo "    [Ready to Refund]  tradeId C: $TRADE_ID_C"
echo "    [Pending]          tradeId D: $TRADE_ID_D"
echo ""
echo "  STATE VERIFICATION"
echo "    A: settle() called at T0+13H ✓"
echo "    B: oracle price set, settle() not called ✓"
echo "    C: grace expired at $(fmt_time $(( TC + 43200 + REFUND_GRACE ))) (1H before frozen) ✓"
echo "    D: endTime $(fmt_time $(( TD + 43200 ))) passed (1H before frozen), no oracle price ✓"
echo ""
echo "  UPDATE .env WITH THESE ADDRESSES:"
echo "    MANUAL_ORACLE_ADDRESS=$ORACLE"
echo "    SPOT_ADDRESS=$SPOT"
echo "============================================================"
