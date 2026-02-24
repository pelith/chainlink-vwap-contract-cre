# Chainlink CRE VWAP 系統設計 (ARCHITECTURE)

## 1. 系統架構 — 10 步結算流程

```
1. 用戶呼叫 fill()
   ↓
2. VWAPRFQSpot 鎖定資金，記錄 startTime, endTime, tradeId
   ↓
3. 後端監聽 Filled event，紀錄 startTime, endTime, tradeId
   ↓
4. 後端 cronjob 掃到期的 trade（endTime 已過且價格尚未寫入）
   ↓
5. 後端觸發 CRE Workflow（HTTP Trigger）
   - 用授權私鑰簽署 HTTP POST 至 CRE DON endpoint
   - Payload: {orderId, startTime, endTime}
   - CRE 驗證 ECDSA 簽名 → 匹配 authorizedKeys
   ↓
6. CRE Workflow DON 執行：
   - 每個節點獨立抓取多個 CEX 數據（指定 startTime~endTime 區間）
   - 每個節點獨立計算 VWAP
   - 執行熔斷檢查（coverage gate, outlier scrubbing, staleness, flash crash）
   - 節點間透過 OCR 共識達成一致
   - 生成 signed report
   ↓
7. Forwarder 將 signed report 寫回鏈上
   - 呼叫 ManualVWAPOracle 的 onReport(bytes metadata, bytes report)
   ↓
8. ManualVWAPOracle 儲存價格：
   - 驗證來自授權 Forwarder
   - 解析 report：startTime, endTime, price
   - 以 keccak256(roundedStart, roundedEnd) 為 key 儲存
   - 發出 PricePublished event
   ↓
9. 任何人可以呼叫 settle()
   - 檢查：endTime 已過 && 在 refund grace 內
   - 呼叫 oracle.getPrice(startTime, endTime) 取得 VWAP 價格
   - 按 VWAP × (10000 + deltaBps) / 10000 執行資金結算
   ↓
10. 後端監聽 Settled event，更新 trade 紀錄
```

---

## 2. 合約架構

```
CRE Workflow (DON)
    │
    │ onReport(bytes metadata, bytes report)
    ▼
Oracle                               ← ManualVWAPOracle (staging)
    │                                   ChainlinkVWAPAdapter (production)
    │  實作 IReceiver + IVWAPOracle
    │  report = abi.encode(startTime, endTime, price)
    │  key = keccak256(roundedStart, roundedEnd)
    │  getPrice(startTime, endTime) → uint256
    ▼
VWAPRFQSpot.settle(tradeId)
    │  reads trade.startTime, trade.endTime
    │  calls oracle.getPrice(...)
    │  adjustedPrice = vwap × (10000 + deltaBps) / 10000
    └─ transfers USDC / WETH to maker & taker
```

---

## 3. 核心設計原則

### 3.1 Settlement > Liveness

Fail-closed：資料不確定時不結算，寧可延遲也不錯誤。

### 3.2 On-Demand，不連續發布

HTTP Trigger 模式，只有在後端觸發時才計算 VWAP，針對特定 (startTime, endTime) 區間。不需要鏈上觸發交易，節省 gas。

### 3.3 多來源獨立計算

每個 CRE 節點獨立：取數據 → 計算 → 熔斷檢查 → 簽名。節點間只在 OCR 共識層做中位數聚合，不共享簽名密鑰。

### 3.4 確定性計算

staleness 檢查以 `endTime` 為基準（不用 `time.Now()`），確保所有節點在歷史模式下產出相同結果。

---

## 4. Report Encoding

Workflow Go 端 encode 格式（`abi.encode(startTime, endTime, price)`）：

```go
// price unit: USDC per 1 ETH scaled by 1e6
// e.g. 2000 USDC/ETH → 2_000_000_000
report = abi.encode(startTime, endTime, price)
```

合約端解碼：

```solidity
(uint256 startTime, uint256 endTime, uint256 price) =
    abi.decode(report, (uint256, uint256, uint256));
```

時間 key 做 round-up to hour：

```solidity
// ((t + 3599) / 3600) * 3600
uint256 roundedStart = _roundUpToHour(startTime);
uint256 roundedEnd   = _roundUpToHour(endTime);
bytes32 key = keccak256(abi.encode(roundedStart, roundedEnd));
```

---

## 5. VWAP 計算邏輯

```
VWAP = Σ(price × volume) / Σ(volume)
```

跨交易所（Binance, OKX, Bybit, Coinbase, Bitget），使用 15 分鐘 K 線，時間區間 = trade.startTime ~ trade.endTime（約 12 小時）。

| 步驟 | 說明 |
|------|------|
| 1. 取數據 | 各節點向 5 家 CEX 請求歷史 K 線 |
| 2. 初步過濾 | 零成交量剔除；缺失 K 線 > 2 筆剔除整個交易所 |
| 3. 各所 VWAP | `VWAP_i = Σ(quoteVol) / Σ(baseVol)` |
| 4. 離群剔除 | 偏離中位數 > 2% 的交易所剔除 |
| 5. 最終聚合 | 有效交易所 >= 3 家時，取成交量加權平均 |

---

## 6. 熔斷機制

Fail-closed：任一檢查失敗 → status != OK → 不產出 report → 不結算。

| 檢查項目 | 閾值 | 說明 |
|---------|------|------|
| Min Venues | >= 3 | 有效交易所數量不足 |
| Staleness | 30 分鐘 | 最新 K 線距 endTime 超過 30 分鐘 |
| Flash Crash | 15% | VWAP 與最近收盤價中位數偏離過大 |
| Outlier | 2% | 偏離整體中位數的交易所被剔除 |

---

## 7. 觸發機制

```
後端 cronjob（每分鐘）
  → 掃描 endTime < now 且 oracle 尚未有價格的 trade
  → 用 BACKEND_PRIVATE_KEY 簽署 HTTP POST
  → Payload: {"orderId":"<id>","startTime":<unix>,"endTime":<unix>}
  → CRE DON 驗證簽名（authorizedKeys）→ 執行 workflow
```

| 階段 | authorizedKeys | 觸發方式 |
|------|---------------|---------|
| Simulate | 空（不需要） | `cre workflow simulate --http-payload` |
| Production | BACKEND_PRIVATE_KEY 對應的 EVM 地址 | 後端簽署 HTTP POST |

---

## 8. 安全模型

- 獨立報告者（每個 CRE 節點獨立計算）
- 不共享簽名密鑰
- Quorum 強制執行
- Staleness 保護（基於 endTime 非 now）
- Fail-closed 結算行為

---

## 9. 已部署合約（Sepolia）

見 [contracts/evm/README.md](./contracts/evm/README.md#deployed-addresses-sepolia)。
