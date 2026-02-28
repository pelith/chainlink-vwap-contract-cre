# VWAP CRE 完整設定與測試指南

---

## Deployment Modes 對照表

| | Hackathon / VTN | Sepolia Staging | Production |
|---|---|---|---|
| **Oracle** | `ManualVWAPOracle` | `ManualVWAPOracle` | `ChainlinkVWAPAdapter` |
| **Forwarder** | `MockKeystoneForwarder` | Real CRE Forwarder | Real CRE Forwarder |
| **FORWARDER_ADDRESS** | `0x15fC...` (mock, no sig check) | `0xF834...` (Sepolia) | `0x0b93...` (Mainnet) |
| **價格寫入** | `simulate-and-forward.sh` | `cmd/trigger/`（真實 DON） | `cmd/trigger/`（真實 DON） |
| **`setPrice()` 後門** | ✅ | ✅ | ❌ |
| **CRE workflow** | `simulate`（dry-run，不上鏈） | `deploy`（真實 DON 執行） | `deploy`（真實 DON 執行） |
| **跳過 12h 等待** | `evm_increaseTime` (VTN) | 等待真實時間 | 等待真實時間 |

> **Hackathon / VTN** 模式的設計原則：`MockKeystoneForwarder` 不驗證任何簽名，任何人都可呼叫 `report()`；`ManualVWAPOracle` 保留 `setPrice()` owner 後門方便直接注入測試價格。兩者組合讓整條 simulate → on-chain 路徑可在無 CRE 帳號的環境完整測試。

---

## 前置需求

- [Foundry](https://getfoundry.sh)（`forge`, `cast`）
- [CRE CLI](https://docs.chain.link/cre/getting-started/installation)（`cre`，需 `cre login`）
- 有 Sepolia ETH 的錢包（deployer）
- 後端簽名用錢包（backend signer，可以和 deployer 同一把）

---

## Part A — Local 驗證（不需要 Sepolia 或 CRE 帳號）

### A1. Go 單元測試

驗證 VWAP 計算、熔斷邏輯、report encoding。

```bash
cd vwap-eth-quote-flow
go test -v
```

### A2. Forge 合約測試

```bash
cd contracts/evm
forge test
```

預期：44 tests 全 PASS。

### A3. CRE Workflow 模擬

驗證 HTTP trigger → 交易所 API → VWAP 計算的完整 workflow。
（不產生鏈上交易）

```bash
# 用 test-payload.json（路徑相對於 workflow 目錄）
cre workflow simulate vwap-eth-quote-flow \
  --non-interactive --trigger-index 0 \
  --http-payload test-payload.json \
  --target staging-settings

# 或是 inline JSON
cre workflow simulate vwap-eth-quote-flow \
  --non-interactive --trigger-index 0 \
  --http-payload '{"orderId":"1","startTime":1739552400,"endTime":1739595600}' \
  --target staging-settings
```

> `Skipping WorkflowEngineV2` 是正常的，模擬不執行鏈上寫入。

---

## Part B — Sepolia 端到端

### B1. 設定環境變數

```bash
cp .env.example .env
```

編輯 `.env`：

```bash
CRE_ETH_PRIVATE_KEY=<deployer 私鑰>       # cre CLI 用
BACKEND_PRIVATE_KEY=<backend signer 私鑰>  # 簽 HTTP trigger 用
DEPLOYER_PRIVATE_KEY=<deployer 私鑰>       # cast / deploy.sh 用
FORWARDER_ADDRESS=0x15fC6ae953E024d975e77382eEeC56A9101f9F88
```

### B2. 推導 backend signer 地址

```bash
./derive-address <BACKEND_PRIVATE_KEY>
# 輸出: 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf
```

記下這個地址，B4 會用到。

### B3. 部署合約到 Sepolia

```bash
cd contracts/evm
ORACLE_MODE=manual ./deploy.sh
```

記下輸出的兩個地址：`ManualVWAPOracle` 和 `VWAPRFQSpot`。

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
      "reserveManagerAddress": "<B3 的 ManualVWAPOracle 地址>",
      "balanceReaderAddress": "0x4b0739c94C1389B55481cb7506c62430cA7211Cf",
      "chainName": "ethereum-testnet-sepolia",
      "gasLimit": 1000000
    }
  ]
}
```

### B5. 部署 CRE Workflow

```bash
cre workflow deploy vwap-eth-quote-flow --target staging-settings
```

部署成功後取得 DON endpoint URL，填進 `.env`：

```bash
CRE_ENDPOINT_URL=<deploy 回傳的 endpoint>
```

### B6. 觸發 HTTP Trigger

```bash
source .env

# 取最近 12 小時區間
START_TIME=$(( ($(date -v-13H +%s) / 900) * 900 ))
END_TIME=$(( ($(date -v-1H +%s) / 900) * 900 ))

go run ./cmd/trigger/ 1 $START_TIME $END_TIME
```

預期：Status 200，CRE DON 開始非同步計算。

### B7. 驗證鏈上結果

等待 1-2 分鐘後，CRE Forwarder 會呼叫 `onReport()`：

```bash
ORACLE=<B3 的 ManualVWAPOracle 地址>

cast call $ORACLE \
  "getPrice(uint256,uint256)(uint256)" \
  $START_TIME $END_TIME \
  --rpc-url ${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}
```

回傳非零值即代表 VWAP 已成功寫入。

---

## 流程總覽

```
[你]                        [Sepolia]                [CRE DON]
 |                              |                        |
 |-- B3: deploy contracts ----->|                        |
 |                              |                        |
 |-- B5: cre workflow deploy ---|----------------------->|
 |                              |                        |
 |-- B6: signed HTTP POST ------|----------------------->|
 |                              |   fetch 5 exchanges    |
 |                              |   compute VWAP         |
 |                              |   OCR consensus        |
 |                              |<-- Forwarder onReport--|
 |-- B7: cast call ------------>|                        |
 |   getPrice?                  |                        |
```

---

## Part C — Tenderly VTN 完整 Demo（Hackathon 推薦）

Tenderly Virtual TestNet（VTN）是 Sepolia 的可程式化 fork，支援時間快轉（`evm_increaseTime`）和餘額設定（`tenderly_setErc20Balance`），不需要等待真實鏈上時間。

### C1. 建立 Tenderly VTN

1. 登入 [Tenderly Dashboard](https://dashboard.tenderly.co)
2. 左側選 **Virtual TestNets** → **Create Virtual TestNet**
3. 選 **Sepolia** 作為 parent network，Fork block 選最新
4. 建立後，進入 VTN 頁面 → **RPC URLs** → 複製 **Admin RPC URL**

### C2. 設定環境變數

在 `.env` 加入：

```bash
TENDERLY_ADMIN_RPC=https://virtual.sepolia.rpc.tenderly.co/<vtn-id>/admin
MANUAL_ORACLE_ADDRESS=   # C3 部署後填入
```

> Admin RPC 支援時間快轉等特權方法，普通 Public RPC 不支援。

### C3. 在 VTN 上部署合約

```bash
cd contracts/evm
RPC_URL=$TENDERLY_ADMIN_RPC ORACLE_MODE=manual ./deploy.sh
```

將輸出的 `ManualVWAPOracle` 地址填入 `.env`：

```bash
MANUAL_ORACLE_ADDRESS=0x<C3 輸出的地址>
```

> VTN fork 自 Sepolia，`MockKeystoneForwarder`（`0x15fC...`）已自動繼承，無需另外部署。`FORWARDER_ADDRESS` 保持預設即可。

### C4. 執行 Simulate → On-chain

`simulate-and-forward.sh` 會完整走過：

1. `cre workflow simulate`（dry-run，從交易所拉資料、計算 VWAP）
2. 解析 `priceE6` 和 `status`
3. 構造 `rawReport`，呼叫 `MockKeystoneForwarder.report()` → `oracle.onReport()`

```bash
# 指定 endTime（會自動 floor 到整點，startTime = endTime - 12h）
RPC_URL=$TENDERLY_ADMIN_RPC ./scripts/simulate-and-forward.sh "2026-02-27 02:00"

# 或用現在時間
RPC_URL=$TENDERLY_ADMIN_RPC ./scripts/simulate-and-forward.sh
```

預期輸出（最後幾行）：
```
Done. Report routed through MockKeystoneForwarder → onReport().
  Forwarder: 0x15fC6ae953E024d975e77382eEeC56A9101f9F88
  Oracle:    0x<MANUAL_ORACLE_ADDRESS>
  PriceE6:   2345678901
```

### C5. 驗證鏈上結果

```bash
cast call $MANUAL_ORACLE_ADDRESS \
  "getPrice(uint256,uint256)(uint256)" \
  $START_TIME $END_TIME \
  --rpc-url $TENDERLY_ADMIN_RPC
```

回傳非零值即代表 VWAP 已成功寫入。

### C6. （選用）快轉時間

若需要測試 RFQ 結算（需等 `endTime` 過後才能 `settle()`），可用 VTN Admin RPC 快轉：

```bash
# 快轉 12 小時（43200 秒）
cast rpc evm_increaseTime 43200 --rpc-url $TENDERLY_ADMIN_RPC
cast rpc evm_mine --rpc-url $TENDERLY_ADMIN_RPC
```

### C7. （選用）設定代幣餘額

若需測試 RFQ 交易，可用 Tenderly 特權方法直接設定 ERC-20 餘額：

```bash
# 設定地址持有 10000 USDC（6 decimals）
cast rpc tenderly_setErc20Balance \
  "<USDC_ADDRESS>" \
  "<YOUR_ADDRESS>" \
  "0x2386F26FC10000" \
  --rpc-url $TENDERLY_ADMIN_RPC
```

---

## 疑難排解

| 問題 | 可能原因 |
|------|---------|
| simulate 時交易所 API 失敗 | 時間範圍太舊（超過交易所保留期限），改用最近 12 小時 |
| `cre workflow deploy` 失敗 | 確認 `cre login` 成功、`CRE_ETH_PRIVATE_KEY` 有 Sepolia ETH |
| `authorizedKeys` 報錯 | 地址需帶 `0x` 前綴，用 `./derive-address` 確認 |
| B7 查不到結果 | 多等幾分鐘，或檢查 CRE dashboard 的 workflow logs |
| `cmd/trigger` 連線失敗 | 確認 `CRE_ENDPOINT_URL` 正確（來自 B5 deploy 輸出）|
| `simulate-and-forward.sh` 解析失敗 | `cre workflow simulate` 輸出可能為警告，需確認 `VWAP result` 那行有出現 |
| VTN 上 `cast code` 回傳空 | VTN fork 時間早於合約部署，需在 VTN 上重新 deploy（見 C3）|
| `ReportProcessed result=false` | `MANUAL_ORACLE_ADDRESS` 填錯，確認 bytecode 含 `onReport` selector（`cast code \| grep 805f2132`）|
| `evm_increaseTime` 失敗 | 確認使用 Admin RPC（不是 Public RPC）；Admin URL 含 `/admin` 後綴 |
