# Chainlink CRE 12h VWAP 結算系統 PRD (v2.1)

## 1. 專案目標 (Objective)
建立一個基於 **Chainlink CRE (Custom Reporting Entity)** 框架的權限化預言機網絡。該系統負責從中心化交易所 (CEX) 獲取原始數據，並透過「中位數去噪」與「最低源數量檢查」產生 12 小時的結算價格。

## 2. 開發前置作業 (Pre-requisites)

### 2.1 基礎環境
- **Go Lang**: 1.21 或更高版本（CRE Workflow 主要以 Go 編寫）。
- **Chainlink CLI**: 需安裝並配置好與目標節點通訊的 Credentials。
- **Docker**: 用於本地模擬節點環境測試 Workflow 確定性 (Determinism)。

### 2.2 網絡與權限
- **Node Address**: 獲取開發節點地址，並確保其已列入鏈上合約的 `Allowlisted Reporters`。
- **CEX API Access**:
    - 目標交易所：**Binance, OKX, Bybit, Coinbase, Bitget**。
    - 交易對：**ETH/USDC**。
    - 上述交易所的 K 線 API 皆為公開端點，無需 API Key。

---

## 3. 價格生成邏輯 (Price Generation Logic)
系統採用 **「中位數參考去噪法 (Median-Reference Scrubbing)」** 以確保單一交易所故障或惡意操縱不影響最終結算。

### 3.1 處理流程：
1. **併發數據獲取 (Multi-Venue Fetching)**：
    - CRE 節點同時向 5 家目標 CEX 請求過去 12 小時的 **15-minute K 線**（共 48 筆/交易所）。
    - **Stateless 處理**：由於 CRE 是無狀態的，節點需一次性獲取完整 12 小時數據。48 筆在所有交易所的單次 API 限制內。
2. **初步過濾 (Sanity Filter)**：
    - **零成交處理**：若該交易所 12h `TotalVolume == 0`，直接剔除。
    - **完整性檢查**：若 48 筆 K 線中缺失數 > 2 筆（約 5%），剔除該源。
3. **基準中位數計算 (Median Benchmark)**：
    - 計算各交易所獨立的 12h VWAP：$VWAP_i = \frac{\sum (Price \times Volume)}{\sum Volume}$。
    - 取得所有有效 VWAP 的**中位數 (Median)**。
4. **離群值剔除 (Outlier Scrubbing)**：
    - 計算各源偏離度：$Deviation_i = \frac{|VWAP_i - Median|}{Median}$。
    - 若 $Deviation_i > 2\%$ (可調參數)，則剔除該交易所數據。
5. **最終聚合與計數 (Final Aggregation & Threshold)**：
    - **核心門檻**：篩選後剩餘的「有效交易所數量」必須 **$\ge 3$**。
    - 若滿足門檻，則對剩餘數據取成交量加權平均值作為最終 `Price`。

### 3.2 CRE 共識模型
- 每個 CRE 節點**獨立完成**全部步驟：抓取 → 計算 → 熔斷檢查 → 產出最終 `(price, status)`。
- 跨節點共識發生在**最終報告層級**，由 CRE DON 對各節點的 `price` 取中位數。
- 個別 HTTP 回應不做跨節點共識。

---

## 4. 熔斷機制 (Circuit Breaker)
本系統嚴格遵守 **Fail-closed** 原則，若發生以下情況，停止報價並回報錯誤：

- **Min Venues Check**: 有效交易所數量 < 3。
- **Staleness Check**: 最新一筆 K 線的時間戳與當前時間差 > 30 分鐘。
- **Flash Crash Protection**: 最終 12h VWAP 與各交易所**最近一根 K 線收盤價的中位數**偏離度 > 15%，視為 VWAP 失效。

---

## 5. 輸出格式 (Report Schema)

MVP 階段沿用 `ReserveManager` 合約的 `UpdateReserves(totalMinted, totalReserve)` 格式：

| 欄位名稱 | 映射 | 說明 |
| :--- | :--- | :--- |
| `totalReserve` | price | 最終 VWAP 報價（8 位精度，1e8） |
| `totalMinted` | metadata | 編碼 `(asOf << 16) \| (sourceCount << 8) \| status` |

其中 status 定義：
- `0`: OK
- `1`: INSUFFICIENT_SOURCES
- `2`: STALE_DATA
- `3`: DEVIATION_ERROR

正式版再部署專用合約。

---

## 6. 安全與稽核要求
- **確定性邏輯 (Deterministic Logic)**：Go 代碼中嚴禁使用 `rand` 或非確定的時間函數，確保 DON 中所有節點計算結果一致。
- **審計路徑**：Report 中應包含各參與交易所的狀態標記，以便鏈下追蹤哪家交易所被剔除。
- **密鑰保護**：節點簽章密鑰應受 HSM 保護，不應以明文形式存在於代碼中。
