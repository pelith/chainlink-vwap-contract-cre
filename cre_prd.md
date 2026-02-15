# Chainlink CRE 12h VWAP 結算系統 PRD (v3.0)

## 1. 專案目標 (Objective)
建立一個基於 **Chainlink CRE (Custom Reporting Entity)** 框架的權限化預言機網絡，為 RFQ Spot 延遲結算系統提供 12 小時 VWAP 結算價格。

系統採用 **事件驅動（on-demand）** 模式：後端在訂單到期時觸發 CRE Workflow，按需計算特定時間區間的 VWAP 並寫回鏈上。

---

## 2. 系統架構 — 10 步結算流程

```
1. 用戶呼叫 fill()
   ↓
2. 主合約鎖定資金，記錄 startTime, endTime, orderId
   ↓
3. 後端監聽 Filled event，紀錄 startTime, endTime, orderId
   ↓
4. 後端 cronjob 掃到期的 order（endTime 已過）
   ↓
5. 後端觸發 CRE Workflow
   - 呼叫 MessageEmitter.emitMessage(JSON: {orderId, startTime, endTime})
   - MessageEmitter 發出 MessageEmitted event
   - CRE DON 透過 Log Trigger 接收事件
   ↓
6. CRE Workflow DON 執行：
   - 每個節點獨立抓取多個 CEX 數據（指定 startTime~endTime 區間）
   - 每個節點獨立計算 VWAP
   - 執行熔斷檢查（coverage gate, outlier scrubbing, staleness, flash crash）
   - 節點間透過 OCR 共識達成一致
   - 生成 signed report
   ↓
7. Forwarder 將 signed report 寫回鏈上合約
   - 呼叫合約的 onReport(bytes metadata, bytes report)
   ↓
8. 鏈上合約驗證並儲存：
   - 驗證簽名來自 Chainlink DON
   - 解析 report：orderId, startTime, endTime, priceE8
   - 儲存至 mapping: settlements[orderId] = {startTime, endTime, priceE8}
   - 發出 PriceSettled event
   ↓
9. 任何人可以呼叫 settle()
   - 檢查：endTime 已到 && 價格已確認（settlements[orderId].settled == true）
   - 按 VWAP 價格 + deltaBps 執行資金結算
   ↓
10. 後端監聽結算 log，更新 order 紀錄
```

---

## 3. 觸發機制

### 3.1 CRE 觸發方式：Log Trigger（非 Cron）

CRE 僅支援兩種觸發方式：**Cron** 和 **Log Trigger**。本系統採用 Log Trigger：

- **MessageEmitter 合約**（已部署）：後端呼叫 `emitMessage(string)` 發出鏈上事件
- **CRE DON** 監聽 `MessageEmitted` 事件，解析 message JSON 取得結算請求
- 觸發後 CRE 計算指定時間區間的 VWAP 並寫回鏈上

### 3.2 後端觸發流程

```
後端 cronjob (每分鐘)
  → 掃描 endTime < now 且尚未結算的訂單
  → 呼叫 MessageEmitter.emitMessage('{"orderId":"<id>","startTime":<unix>,"endTime":<unix>}')
  → CRE DON 收到 event → 開始 VWAP 計算
```

### 3.3 Settlement Request 格式

MessageEmitter message 內容為 JSON 字串：
```json
{
  "orderId": "123",
  "startTime": 1700000000,
  "endTime": 1700043200
}
```
- `orderId`: 訂單 ID（uint256，十進位字串）
- `startTime`: VWAP 計算起始時間（unix seconds）
- `endTime`: VWAP 計算結束時間（unix seconds）

---

## 4. 價格生成邏輯 (Price Generation Logic)

系統採用 **「中位數參考去噪法 (Median-Reference Scrubbing)」** 以確保單一交易所故障或惡意操縱不影響最終結算。

### 4.1 處理流程

1. **數據獲取**：CRE 節點向 5 家 CEX 請求指定時間區間（startTime~endTime）的 15 分鐘 K 線
   - 交易所：Binance, OKX, Bybit, Coinbase, Bitget
   - 交易對：ETH/USDC
   - 使用各交易所 API 的時間範圍參數取得歷史 K 線
2. **初步過濾**：
   - 零成交量：剔除
   - 缺失 K 線 > 2 筆：剔除
3. **基準中位數計算**：
   - 各交易所獨立 VWAP：`VWAP_i = Σ(quoteVol) / Σ(baseVol)`
   - 取所有有效 VWAP 的中位數
4. **離群值剔除**：偏離中位數 > 2% 的交易所剔除
5. **最終聚合**：
   - 有效交易所 >= 3 家
   - 對剩餘交易所取成交量加權平均

### 4.2 CRE 共識模型

- 每個 CRE 節點**獨立完成**全部步驟：抓取 → 計算 → 熔斷檢查 → 產出 `(price, status)`
- 跨節點共識發生在**最終報告層級**，由 CRE DON 對各節點的結果取中位數
- 個別 HTTP 回應不做跨節點共識

---

## 5. 熔斷機制 (Circuit Breaker)

嚴格遵守 **Fail-closed** 原則：

| 檢查項目 | 閾值 | 說明 |
|---------|------|------|
| Min Venues | >= 3 | 有效交易所數量不足則失敗 |
| Staleness | 30 分鐘 | 最新 K 線距 endTime 超過 30 分鐘則失敗 |
| Flash Crash | 15% | VWAP 與最近收盤價中位數偏離超過 15% 則失敗 |
| Outlier Deviation | 2% | 超過此閾值的交易所被剔除 |

熔斷時 status != OK，CRE 不產出報告，結算不執行。

---

## 6. 鏈上合約 (On-chain Contracts)

### 6.1 VWAPSettlement 合約

實作 `IReceiver` 介面，接收 CRE signed report：

```solidity
contract VWAPSettlement is IReceiver {
    struct Settlement {
        uint64 startTime;
        uint64 endTime;
        uint64 priceE8;
        bool settled;
    }

    mapping(uint256 => Settlement) public settlements;

    function onReport(bytes calldata, bytes calldata report) external;
    function getPrice(uint256 orderId) external view returns (uint64, uint64, uint64);
    function isSettled(uint256 orderId) external view returns (bool);
}
```

### 6.2 Report 編碼格式

複用 `UpdateReserves(uint256 totalMinted, uint256 totalReserve)` 格式：

| 欄位 | 映射 | 說明 |
|------|------|------|
| `totalMinted` | orderId | 訂單 ID |
| `totalReserve` | packed data | `(startTime << 128) \| (endTime << 64) \| priceE8` |

合約端解碼：
```solidity
uint256 orderId = totalMinted;
uint64 startTime = uint64(packed >> 128);
uint64 endTime = uint64(packed >> 64);
uint64 priceE8 = uint64(packed);
```

### 6.3 已部署合約（Sepolia Testnet）

| 合約 | 地址 | 用途 |
|------|------|------|
| MessageEmitter | `0x1d598672486ecB50685Da5497390571Ac4E93FDc` | 後端觸發 CRE 的橋接 |
| ReserveManager | `0x51933aD3A79c770cb6800585325649494120401a` | MVP 接收報告（將替換為 VWAPSettlement） |

---

## 7. CRE Workflow 設計

### 7.1 觸發器

- **Log Trigger**：監聽 MessageEmitter 的 `MessageEmitted` 事件
- 事件觸發後，解析 message JSON 取得 `{orderId, startTime, endTime}`

### 7.2 動態 URL 構建

根據 startTime/endTime 構建各交易所的歷史 K 線 API URL：

| 交易所 | 時間參數格式 |
|--------|-------------|
| Binance | `startTime=<ms>&endTime=<ms>` |
| OKX | `after=<startMs>&before=<endMs>` |
| Bybit | `start=<ms>&end=<ms>` |
| Coinbase | `start=<sec>&end=<sec>` |
| Bitget | `startTime=<ms>&endTime=<ms>` |

### 7.3 Workflow 流程

```
MessageEmitted event
  → 解析 settlement request
  → 構建動態 exchange URLs（指定時間區間）
  → 併發請求 5 家交易所
  → 計算 VWAP + 熔斷檢查
  → 編碼 report (orderId, packed)
  → 寫回鏈上 VWAPSettlement 合約
```

---

## 8. 安全與稽核要求

- **確定性邏輯**：Go 代碼中嚴禁使用 `rand` 或非確定的時間函數
- **歷史數據模式**：staleness 檢查基於 `endTime`（而非 `time.Now()`），確保節點間一致
- **密鑰保護**：節點簽章密鑰應受 HSM 保護
- **Fail-closed**：任何異常情況下不產出報告，寧可延遲結算也不錯誤結算
