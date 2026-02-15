# CRE Oracle – Background Knowledge

## 1. Why CRE Oracle Exists

CRE Oracle is designed to provide a settlement-grade price source
for delayed settlement mechanisms (e.g., 12h VWAP-based RFQ).

The system is NOT intended to:
- Replace major oracle networks (e.g., Chainlink)
- Compete as a public oracle product
- Provide high-frequency trading signals

It IS intended to:
- Provide deterministic, auditable 12h VWAP settlement price
- Be resilient to single venue failure
- Fail closed rather than settle on incorrect data
- Abstract the price service layer from settlement logic

---

## 2. System Architecture — 10-Step Settlement Flow

```
1. User calls fill()
   ↓
2. Main contract locks funds, records startTime, endTime, orderId
   ↓
3. Backend listens to Filled event, records startTime, endTime, orderId
   ↓
4. Backend cronjob scans for expired orders (endTime has passed)
   ↓
5. Backend triggers CRE Workflow
   - Calls MessageEmitter.emitMessage(JSON: {orderId, startTime, endTime})
   - MessageEmitter emits MessageEmitted event
   - CRE DON picks up event via Log Trigger
   ↓
6. CRE Workflow DON executes:
   - Each node independently fetches CEX data (for startTime~endTime range)
   - Each node independently computes VWAP
   - Circuit breaker checks (coverage gate, outlier scrubbing, staleness, flash crash)
   - Nodes reach consensus via OCR
   - Generate signed report
   ↓
7. Forwarder writes signed report on-chain
   - Calls contract's onReport(bytes metadata, bytes report)
   ↓
8. On-chain contract verifies and stores:
   - Verifies signatures from Chainlink DON
   - Decodes report: orderId, startTime, endTime, priceE8
   - Stores to mapping: settlements[orderId] = {startTime, endTime, priceE8}
   - Emits PriceSettled event
   ↓
9. Anyone can call settle()
   - Checks: endTime has passed && price is confirmed
   - Executes settlement at VWAP price + deltaBps
   ↓
10. Backend listens to settlement log, updates order records
```

---

## 3. Core Design Philosophy

### 3.1 Settlement > Liveness

If data integrity is uncertain:
→ Do NOT settle.

Fail-closed is preferred over wrong settlement.

---

### 3.2 On-Demand, Not Continuous

The system operates in **event-driven mode**:
- CRE does NOT continuously publish prices
- CRE computes VWAP only when triggered by a settlement request
- Each computation targets a specific (startTime, endTime) range
- This avoids unnecessary gas costs and data staleness issues

The trigger chain:
- Backend → MessageEmitter.emitMessage() → on-chain event
- CRE DON → Log Trigger → picks up event → computes → writes back

---

### 3.3 Multi-Source, Not Multi-Hop

Each CRE node must:
- Independently fetch exchange data
- Independently compute price
- Independently sign report

Nodes must NOT:
- Rely on a central aggregator service
- Share a signing key
- Blindly relay another node's result

Security is derived from:
- Independent computation
- Quorum-based aggregation
- Median or trimmed mean selection

---

### 3.4 Deterministic Computation

All price calculation logic must be:

- Deterministic
- Versioned
- Reproducible from historical data

Given:
- Time window (startTime, endTime)
- Venue list
- Raw trade data

Any third party should be able to reproduce the VWAP result.

**Important**: For historical mode, staleness checks use `endTime` as reference
(not `time.Now()`), ensuring all nodes produce identical results.

---

## 4. What VWAP Actually Means Here

12h VWAP:

VWAP = Σ(price × volume) / Σ(volume)

Applied across:
- Multiple exchanges
- Filtered venues
- Specific time window (startTime to endTime, typically 12 hours)

This is NOT:
- Instant spot price
- Oracle network median
- TWAP

VWAP represents historical trading-weighted fair price.

---

## 5. Why Sanity Checks Are Required

VWAP alone is insufficient because:

- Exchange APIs may fail
- Thin venues may distort volume
- Data latency may cause anomalies

Therefore, the system requires:

1. Coverage gate
   Minimum number of venues available (>= 3).

2. Dispersion control
   Detect abnormal cross-venue divergence (> 2% from median).

3. Staleness check
   Latest candle must be within 30 minutes of endTime.

4. Flash crash protection
   VWAP vs median of last candle closes must not diverge > 15%.

Sanity checks protect against:
- Data corruption
- Manipulated thin markets
- Infrastructure failures

---

## 6. On-Chain Contract Design

### 6.1 Report Encoding

Reuses `UpdateReserves(uint256 totalMinted, uint256 totalReserve)` format
to avoid generating new Go bindings:

- `totalMinted` = orderId
- `totalReserve` = (startTime << 128) | (endTime << 64) | priceE8

### 6.2 VWAPSettlement Contract

Implements IReceiver, stores `orderId → {startTime, endTime, priceE8, settled}`.

### 6.3 Deployed Contracts (Sepolia)

- MessageEmitter: `0x1d598672486ecB50685Da5497390571Ac4E93FDc`
- ReserveManager: `0x51933aD3A79c770cb6800585325649494120401a` (MVP, to be replaced)

---

## 7. Security Model

Security relies on:

1. Independent reporters
2. Non-shared signing keys
3. Quorum enforcement
4. Staleness protection
5. Fail-closed settlement behavior

If:
- Coverage insufficient
- Deviation too large
- Data stale

Then:
→ status != OK
→ Settlement must not proceed.

---

## 8. Trade-Offs

| Property | VWAP | TWAP | Spot |
|----------|------|------|------|
| Fair historical execution | Yes | Partial | No |
| Trend lag | High | Medium | None |
| Manipulation resistance | Depends on volume quality | High | Medium |
| Complexity | High | Medium | Low |

CRE Oracle accepts higher complexity
to achieve fair historical settlement.

---

## 9. Operational Philosophy

CRE Oracle is not optimized for:
- Ultra-low latency
- Per-block updates
- Arbitrage precision

It is optimized for:
- Robust 12-hour settlement
- Deterministic replay
- Governance-controlled safety
- On-demand computation (no wasted gas)

---

## 10. Final Principle

If correctness and availability conflict,
correctness wins.

Settlement delay is acceptable.
Incorrect settlement is not.

claude user language: 繁體中文
