# VWAP CRE 完整測試指南

從零到鏈上驗證的 step-by-step。

---

## 前置需求

- [Foundry](https://getfoundry.sh) (`forge`, `cast`, `anvil`)
- [CRE CLI](https://docs.chain.link/cre/getting-started/installation) (`cre`)
- CRE 帳號（已 `cre login`）
- 一個有 Sepolia ETH 的錢包（deployer）
- 一個後端簽名用錢包（backend signer，可以跟 deployer 同一把）

---

## Part A — Local 驗證（不需要 CRE 帳號）

### A1. 跑 Go 單元測試

驗證 VWAP 計算、熔斷邏輯、report 編碼。

```bash
cd vwap-eth-quote-flow
go test -v
```

預期：8 個 test 全 PASS。

### A2. 跑 Anvil 合約測試

驗證 VWAPSettlement 合約的 `onReport()` 解碼正確。

```bash
cd contracts/evm
./test-anvil.sh
```

預期：ALL TESTS PASSED。

### A3. CRE Workflow 模擬

驗證 HTTP trigger → 交易所 API → VWAP 計算 → report 編碼的完整 workflow。
（不會產生鏈上交易，最後一步 chain write 會被跳過）

```bash
# 從 project root 執行
./scripts/simulate.sh
```

或手動指定 payload：
```bash
./scripts/simulate.sh '{"orderId":"1","startTime":1739552400,"endTime":1739595600}'
```

預期：看到 `Workflow Simulation Result` 和計算出的 VWAP 數據。

> 如果看到 `Skipping WorkflowEngineV2` 是正常的 — 模擬不執行鏈上寫入。

---

## Part B — Sepolia 端到端測試

### B1. 設定環境變數

```bash
cp .env.example .env
```

編輯 `.env`：

```bash
# CRE CLI 用（Sepolia 上需要有 ETH）
CRE_ETH_PRIVATE_KEY=<你的 deployer 私鑰>
CRE_TARGET=staging-settings

# 後端觸發用（可以跟 deployer 同一把，也可以分開）
BACKEND_PRIVATE_KEY=<你的 backend signer 私鑰>

# 部署合約用
DEPLOYER_PRIVATE_KEY=<你的 deployer 私鑰>
```

### B2. 推導 backend signer 地址

```bash
go run ./cmd/derive-address/ <BACKEND_PRIVATE_KEY>
# 輸出: 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf
```

記下這個地址，下一步要用。

### B3. 部署 VWAPSettlement 合約到 Sepolia

```bash
cd contracts/evm
PRIVATE_KEY=0x<DEPLOYER_PRIVATE_KEY> ./deploy.sh
```

記下輸出的 `Deployed at: 0x...` 地址。

### B4. 更新 config

編輯 `vwap-eth-quote-flow/config.staging.json`：

```json
{
  "deviationThresholdPct": 2.0,
  "minVenues": 3,
  "maxStalenessMinutes": 30,
  "flashCrashPct": 15.0,
  "maxMissingCandles": 2,
  "authorizedKeys": ["<B2 得到的 backend signer 地址>"],
  "evms": [
    {
      "tokenAddress": "0x4700A50d858Cb281847ca4Ee0938F80DEfB3F1dd",
      "reserveManagerAddress": "<B3 部署的 VWAPSettlement 地址>",
      "balanceReaderAddress": "0x4b0739c94C1389B55481cb7506c62430cA7211Cf",
      "chainName": "ethereum-testnet-sepolia",
      "gasLimit": 1000000
    }
  ]
}
```

### B5. 部署 CRE Workflow 到 DON

```bash
cd vwap-eth-quote-flow
cre workflow deploy --target staging-settings
```

部署成功後會得到 workflow endpoint URL。把它填進 `.env`：
```bash
CRE_ENDPOINT_URL=<deploy 回傳的 endpoint>
```

### B6. 觸發 HTTP Trigger

構造一個結算請求（12 小時前到 1 小時前的 VWAP）：

```bash
# 計算時間（對齊 15 分鐘邊界）
START_TIME=$(( ($(date -v-13H +%s) / 900) * 900 ))
END_TIME=$(( ($(date -v-1H +%s) / 900) * 900 ))

echo "startTime: $START_TIME"
echo "endTime:   $END_TIME"

# 載入環境變數
source .env

# 發送簽名 HTTP POST
go run ./cmd/trigger/ 1 $START_TIME $END_TIME
```

預期：Status 200，CRE DON 開始非同步計算。

### B7. 驗證鏈上結果

等待約 1-2 分鐘後，CRE DON 會透過 Forwarder 將 signed report 寫上鏈。

```bash
source .env
CONTRACT=<B3 部署的 VWAPSettlement 地址>
RPC=https://ethereum-sepolia-rpc.publicnode.com

# 檢查價格是否已寫入
cast call $CONTRACT "isSettled(uint256)(bool)" 1 --rpc-url $RPC

# 查看結算數據
cast call $CONTRACT "getPrice(uint256)(uint64,uint64,uint64)" 1 --rpc-url $RPC
```

預期：
- `isSettled(1)` = `true`
- `getPrice(1)` 回傳 `(startTime, endTime, priceE8)`，priceE8 是 ETH/USD 價格 × 10^8

---

## 流程總覽

```
[你]                        [Sepolia]                [CRE DON]
 |                              |                        |
 |-- B3: deploy contract ------>|                        |
 |                              |                        |
 |-- B5: cre workflow deploy ---|----------------------->|
 |                              |                        |
 |-- B6: signed HTTP POST -----|----------------------->|
 |                              |                        |
 |                              |   fetch 5 exchanges    |
 |                              |   compute VWAP         |
 |                              |   OCR consensus        |
 |                              |<-- Forwarder writes ---|
 |                              |   onReport(report)     |
 |                              |                        |
 |-- B7: cast call ----------->|                        |
 |   isSettled? getPrice?       |                        |
```

---

## 疑難排解

| 問題 | 可能原因 |
|------|---------|
| simulate 時交易所 API 失敗 | 時間範圍太舊（超過交易所保留期限），用最近 12 小時 |
| `cre workflow deploy` 失敗 | 確認 `cre login` 成功、`CRE_ETH_PRIVATE_KEY` 有 Sepolia ETH |
| `authorizedKeys` 報錯 | 地址格式要帶 `0x` 前綴，用 `cmd/derive-address` 確認 |
| B7 查不到結果 | 等久一點（DON 共識需要時間），或檢查 CRE UI 的 workflow logs |
| `cmd/trigger` 連線失敗 | 確認 `CRE_ENDPOINT_URL` 正確（來自 deploy 輸出）|
