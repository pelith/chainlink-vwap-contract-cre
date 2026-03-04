# Chainlink CRE — VWAP RFQ Spot

A settlement-grade 12h VWAP oracle for delayed RFQ spot trading, built on Chainlink CRE (Custom Reporting Entity).

---

## What This Is

A spot exchange where trades settle at the **12-hour VWAP price** computed by a decentralized Chainlink DON:

- Maker signs an EIP-712 order off-chain
- Taker calls `fill()` on-chain to lock funds for 12 hours
- Backend triggers the CRE Workflow via HTTP when the window closes
- CRE nodes independently fetch multi-exchange data, compute VWAP, and reach OCR consensus
- Forwarder writes the signed price report to `ManualVWAPOracle` on-chain
- Anyone calls `settle()` to distribute funds at the VWAP-adjusted price

---

## Settlement Flow

```
1. Taker calls fill()
   → Contract locks WETH + USDC, records startTime/endTime

2. Backend detects Filled event
   → Waits for endTime to pass

3. Backend triggers CRE Workflow (signed HTTP POST)
   → Payload: { startTime, endTime }

4. CRE DON executes workflow
   → Each node independently fetches Binance/OKX/Bybit/Coinbase/Bitget
   → Each node independently computes VWAP
   → Circuit breaker checks (coverage, staleness, flash crash, outlier)
   → OCR consensus → signed report

5. Forwarder writes report on-chain
   → ManualVWAPOracle stores price keyed by (roundedStart, roundedEnd)

6. Anyone calls settle()
   → VWAPRFQSpot reads oracle price, applies deltaBps, distributes funds
```

---

## Repository Structure

```
.
├── vwap-eth-quote-flow/        # CRE Workflow (Go) — VWAP computation + on-chain write
│   ├── workflow.go             # Main workflow logic
│   ├── workflow_test.go        # Unit tests
│   ├── config.staging.json     # Staging config (oracle address, authorized keys)
│   └── workflow.yaml           # CRE CLI target settings
├── contracts/evm/              # Solidity contracts
│   ├── src/
│   │   ├── VWAPRFQSpot.sol         # Main exchange: fill / settle / refund
│   │   ├── ChainlinkVWAPAdapter.sol # Production oracle (immutable forwarder)
│   │   ├── ManualVWAPOracle.sol    # Staging oracle (+ manual setPrice backdoor)
│   │   └── IVWAPOracle.sol         # Oracle interface
│   └── deploy.sh               # Deploy script (ORACLE_MODE=manual|chainlink)
├── cmd/trigger/                # Backend trigger: signs and sends HTTP POST to CRE DON
├── scripts/                    # simulate.sh, simulate-and-forward.sh, demo-vtn.sh
├── ARCHITECTURE.md             # System design, VWAP logic, circuit breakers
└── project.yaml                # CRE CLI project settings
```

---

## Deployed Contracts (Sepolia)

See [contracts/evm/README.md](./contracts/evm/README.md#deployed-addresses-sepolia).

---

## Quick Start

**Simulate workflow locally (no CRE account needed):**
```bash
cd vwap-eth-quote-flow
go test -v

# Simulate past 12h (defaults to now)
./scripts/simulate.sh

# Simulate specific end time
./scripts/simulate.sh "2025-02-15 15:00"
```

**Simulate + write on-chain (MockKeystoneForwarder):**
```bash
./scripts/simulate-and-forward.sh
```

**Deploy to Sepolia:**
```bash
# Set DEPLOYER_PRIVATE_KEY in .env, then:
cd contracts/evm
ORACLE_MODE=manual ./deploy.sh
```

**Trigger CRE Workflow (production DON):**
```bash
source .env
go run ./cmd/trigger/ <endTime>
```
