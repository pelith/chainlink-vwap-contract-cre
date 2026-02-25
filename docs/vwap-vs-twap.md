# VWAP vs TWAP：為什麼 VWAP Oracle 難以在鏈上實現

## 1. TWAP 為何能在鏈上做

Uniswap TWAP 的設計只需要兩個東西：

```
TWAP = Σ(price × Δt) / Σ(Δt)
```

| 需要的資料 | 在鏈上嗎 |
|-----------|---------|
| 每筆 swap 的價格 | ✅ |
| 每個區塊的時間戳 | ✅ |

Uniswap 用 **cumulative price accumulator** 將計算壓縮成兩個快照相減，完全 trustless、完全 on-chain、不需要外部資料。

---

## 2. VWAP 為什麼不能這樣做

VWAP 多了一個致命需求：**Volume（成交量）**

```
VWAP = Σ(price × volume) / Σ(volume)
```

### 問題 1：單一 DEX 的 volume 不代表市場

- Binance ETH 日交易量 >> 所有 DEX 加總
- 如果只用 Uniswap 成交量，計算出來的是「Uniswap VWAP」而非「市場 VWAP」
- 對於大額 RFQ 結算，這個數字不夠代表性

### 問題 2：鏈上單一 DEX 的 VWAP 容易被操縱

- **TWAP 防操縱邏輯**：要拉高 TWAP，必須維持高價格很長時間 → 成本是時間
- **VWAP 防操縱邏輯**：攻擊者用 flash loan 做 wash trade，以極低成本製造大量假 volume

詳細的 DEX VWAP 攻擊機制見第 4 節。

### 問題 3：計算是 on-demand，不是 continuous

傳統 oracle feed：
```
每 X 秒推送最新價格 → 合約讀取
```

VWAP 的需求：
```
給我 startTime=T1, endTime=T2 這段時間的 VWAP
→ 每個訂單的 T1/T2 都不同
→ 不可能預先計算並 cache 所有組合
```

不過，這個問題可以透過 cumulative accumulator 設計解決（見第 3 節）。

---

## 3. Cumulative Accumulator 設計：能否學 Uniswap？

一個直覺的設計是：模仿 Uniswap TWAP，改存累計成交量。

```solidity
struct Observation {
    uint32  timestamp;
    uint256 cumulativeTokenA;  // Σ amountA（e.g. ETH）
    uint256 cumulativeTokenB;  // Σ amountB（e.g. USDC）
}

// 查詢任意窗口的 VWAP
function getVWAP(uint T1, uint T2) {
    ΔA = cumulativeA[T2] - cumulativeA[T1]
    ΔB = cumulativeB[T2] - cumulativeB[T1]
    return ΔB / ΔA  // USDC per ETH
}
```

這其實是真正的 VWAP 數學：**total value traded / total quantity traded**，比 TWAP 更直觀。
Uniswap v3 的 observations array 做的就是類似的事（只是存的是 `price × Δt`）。

**這個設計在技術上完全可行**，任意時間窗口都能查詢，on-chain 計算成本低。

但它繼承了 DEX VWAP 的操縱問題（見第 4 節），而且只有 DEX 的成交量，無法代表整體市場。

---

## 4. 為什麼 DEX Cumulative VWAP 仍然可被操縱

### Flash loan + atomic wash trade

攻擊者可以在**同一筆 tx** 內打包買入和賣出，套利者無法插入：

```
同一筆 tx：
  1. Flash loan 借 10,000 ETH（零成本）
  2. Swap：買入 ETH → 池子價格被推高
  3. Swap：賣回 ETH → 池子價格回來
  4. 還 flash loan
整筆 tx atomic commit，套利者無法在步驟 2、3 之間插入
```

cumulativeETH 和 cumulativeUSDC 都記錄了這筆巨量，但兩筆交易都發生在偏離市價的區間。

### AMM 的幾何平均偏差

直覺上以為「買貴賣便宜會抵銷」，但實際不是。以 constant product AMM 計算：

```
初始：1000 ETH / 3,000,000 USDC，市價 $3,000

買入 100 ETH：
  新 USDC = 3×10⁹ / 900 = 3,333,333
  付出 USDC = 333,333
  平均成交價 = $3,333  ← 不是 $3,000

賣回 100 ETH：
  新 USDC = 3×10⁹ / 1000 = 3,000,000
  收到 USDC = 333,333
  平均成交價 = $3,333  ← 也不是 $3,000

Wash trade 的 VWAP 貢獻：
  666,666 USDC / 200 ETH = $3,333（偏差 +11%）
```

**關鍵原因**：constant product AMM 中，每筆交易的平均成交價是
起點和終點價格的**幾何平均數**，永遠不會回到真實市價。
買和賣都發生在 $3,000 ～ $3,704 的中間區間，從未貼近 $3,000。

### 攻擊者可控制偏差方向

| 目的 | 操作 | 效果 |
|------|------|------|
| 拉高 VWAP | 先大量買入再賣回 | volume 記錄在高於市價的區間 |
| 壓低 VWAP | 先大量賣出再買回 | volume 記錄在低於市價的區間 |

成本只有手續費（0.3% × 2），flash loan 不需自有資金。

---

## 5. VWAP Oracle 的需求清單

| 需求 | 為什麼需要 | 能不能在鏈上做 |
|------|-----------|--------------|
| 多交易所 CEX 歷史資料 | Binance/Coinbase volume 才代表市場 | **不行**，鏈上拿不到 |
| 跨交易所 aggregation | 單一 venue 容易操縱 | **不行**，需要 off-chain |
| 特定時間窗口計算 | 每筆訂單 T1/T2 不同 | cumulative 設計可解決 |
| 異常值過濾 | 防止薄流動性場所扭曲 | **不行**，需要業務邏輯 |

**結論：VWAP 的計算本身可以在鏈上做，但「做對的資料來源」天然在 off-chain。**

---

## 6. 為什麼 CRE 是對的工具

CRE 的 DON 計算模型剛好能解決上述問題：

1. 每個節點**獨立**從 CEX API 拉取歷史 K 線資料（Binance、Coinbase、Kraken）
2. 每個節點**獨立**計算 VWAP（不依賴中心化服務）
3. OCR 共識確保多數節點結果一致才寫上鏈
4. HTTP Trigger 讓計算是 on-demand（省 gas、不浪費算力）

CEX 上沒有 flash loan，也無法用 atomic tx 跨交易所做 round-trip，
這是 CEX 多 venue 資料根本上優於鏈上 DEX 資料的原因。

---

## 7. 對照表：三種價格的比較

| 特性 | VWAP | TWAP | Spot |
|------|------|------|------|
| 歷史公平執行 | ✅ 最佳 | 部分 | ❌ |
| 大額結算代表性 | ✅ 業界標準 | 普通 | ❌ |
| 操縱難度（鏈上單一 DEX） | ⚠️ 較低（幾何均價偏差） | ✅ 高（需跨塊維持） | ⚠️ 中 |
| 操縱難度（多 CEX 聚合） | ✅ 高 | — | — |
| 能否純 on-chain 計算 | ⚠️ 可以但資料有問題 | ✅ | ✅ |
| 適合延遲結算 | ✅ | 普通 | ❌ |
| 需要 off-chain compute | ✅ 是（資料來源） | ❌ 否 | ❌ 否 |

---

## 8. 小結

鏈上 DEX VWAP 的 cumulative accumulator 設計在技術上是優雅可行的，
但有兩個根本限制：

1. **資料代表性**：DEX 成交量只是市場的一小部分
2. **幾何均價偏差**：AMM 的 constant product 特性讓 wash trade 的平均成交價
   永遠偏離真實市價，且方向可被攻擊者控制

CRE 提供去中心化的 off-chain compute，讓多 venue CEX 資料可以在無中心化信任的前提下完成聚合，並透過 OCR 共識上鏈，是目前最接近「正確的 VWAP」的實作路徑。
