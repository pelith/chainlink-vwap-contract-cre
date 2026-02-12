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

## 2. Core Design Philosophy

### 2.1 Settlement > Liveness

If data integrity is uncertain:
→ Do NOT settle.

Fail-closed is preferred over wrong settlement.

---

### 2.2 Multi-Source, Not Multi-Hop

Each CRE node must:
- Independently fetch exchange data
- Independently compute price
- Independently sign report

Nodes must NOT:
- Rely on a central aggregator service
- Share a signing key
- Blindly relay another node’s result

Security is derived from:
- Independent computation
- Quorum-based aggregation
- Median or trimmed mean selection

---

### 2.3 Deterministic Computation

All price calculation logic must be:

- Deterministic
- Versioned
- Reproducible from historical data

Given:
- Window
- Venue list
- Raw trade data

Any third party should be able to reproduce the VWAP result.

---

## 3. What VWAP Actually Means Here

12h VWAP:

VWAP = Σ(price × volume) / Σ(volume)

Applied across:
- Multiple exchanges
- Filtered venues
- 12-hour rolling window

This is NOT:
- Instant spot price
- Oracle network median
- TWAP

VWAP represents historical trading-weighted fair price.

---

## 4. Why Sanity Checks Are Required

VWAP alone is insufficient because:

- Exchange APIs may fail
- Thin venues may distort volume
- Data latency may cause anomalies

Therefore, the system requires:

1. Coverage gate
   Minimum percentage of venues available.

2. Dispersion control
   Detect abnormal cross-venue divergence.

3. Optional time-scale sanity reference
   Compare VWAP_12h vs TWAP_12h (not vs spot).

Sanity checks protect against:
- Data corruption
- Manipulated thin markets
- Infrastructure failures

---

## 5. Oracle Network Model

CRE Oracle is a **permissioned distributed network**.

It is NOT:
- Fully permissionless
- Open to arbitrary reporters

On-chain contract must:
- Maintain reporter allowlist
- Require quorum (e.g., 3/5)
- Aggregate using median

Governance must be able to:
- Add/remove reporters
- Adjust quorum
- Update calculation parameters

---

## 6. Security Model

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

## 7. Why Not Use Spot Directly?

Spot price:
- Reflects current price
- Can differ significantly from 12h VWAP in trending markets

Using spot as settlement:
- Breaks fairness of delayed settlement
- Introduces volatility exposure

Using spot only as sanity reference:
- Prevents extreme mispricing
- Does not override VWAP logic

---

## 8. Trade-Offs

| Property | VWAP | TWAP | Spot |
|----------|------|------|------|
| Fair historical execution | ✅ | ⚠️ | ❌ |
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

---

## 10. Final Principle

If correctness and availability conflict,
correctness wins.

Settlement delay is acceptable.
Incorrect settlement is not.

claude user language: 繁體中文
