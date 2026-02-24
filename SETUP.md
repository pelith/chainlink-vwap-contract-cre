# VWAP CRE 完整設定與測試指南

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
RPC=https://ethereum-sepolia-rpc.publicnode.com

cast call $ORACLE \
  "getPrice(uint256,uint256)(uint256)" \
  $START_TIME $END_TIME \
  --rpc-url $RPC
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

## 疑難排解

| 問題 | 可能原因 |
|------|---------|
| simulate 時交易所 API 失敗 | 時間範圍太舊（超過交易所保留期限），改用最近 12 小時 |
| `cre workflow deploy` 失敗 | 確認 `cre login` 成功、`CRE_ETH_PRIVATE_KEY` 有 Sepolia ETH |
| `authorizedKeys` 報錯 | 地址需帶 `0x` 前綴，用 `./derive-address` 確認 |
| B7 查不到結果 | 多等幾分鐘，或檢查 CRE dashboard 的 workflow logs |
| `cmd/trigger` 連線失敗 | 確認 `CRE_ENDPOINT_URL` 正確（來自 B5 deploy 輸出）|
