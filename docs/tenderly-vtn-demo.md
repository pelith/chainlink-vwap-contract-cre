# Tenderly VTN Demo Plan

## 目的

在 Tenderly Virtual TestNet 上跑一支 demo script，一次建立多張訂單並停留在不同狀態，
讓 UI / Tenderly Explorer 能同時展示整個 settlement 生命週期。

---

## 為什麼用 Tenderly VTN

| 痛點 | VTN 解法 |
|------|---------|
| 12h VWAP 需要真的等 12 小時 | `evm_setNextBlockTimestamp` 秒速推進時間 |
| Public testnet faucet 限制多 | VTN 內建無限 faucet |
| 測試環境狀態難重現 | VTN 快照可重複使用 |
| 需要展示所有訂單狀態 | VTN 時間凍結，狀態永久保留 |

---

## Demo Script 流程

### 前置

1. 手動在 Tenderly UI 建立一個 Virtual TestNet（fork Sepolia 或 mainnet）
2. 取得 Admin RPC URL（Tenderly Dashboard → Virtual TestNets → 你的 VTN → RPC URLs → Admin）
3. 把設定填入 `.env`：
   ```bash
   TENDERLY_ADMIN_RPC=https://virtual.sepolia.us-west.rpc.tenderly.co/<id>
   DEPLOYER_PRIVATE_KEY=0x...
   ```
4. 執行 `scripts/demo-vtn.sh`

---

## 訂單狀態矩陣（Demo 範圍）

最終凍結時間：T0+38H，`REFUND_GRACE = 24H`。

| 訂單 | Fill 時間 | 是否 setPrice | 是否 settle | 最終狀態 |
|------|---------|--------------|------------|---------|
| Order A | T0+0H   | ✓ (T0+13H)   | ✓ (T0+13H) | **Settled** |
| Order B | T0+13H  | ✓ (T0+38H)   | ✗          | **Ready to Settle** |
| Order C | T0+1H   | ✗            | ✗          | **Ready to Refund** |
| Order D | T0+25H  | ✗            | ✗          | **Pending** |

---

## 時間操作方式

使用 Admin RPC 的 `evm_setNextBlockTimestamp`：

```bash
curl -X POST $TENDERLY_ADMIN_RPC \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "evm_setNextBlockTimestamp",
    "params": ["<target_timestamp_hex>"],
    "id": 1
  }'
```

T0 設定為下一個整點（exact hour boundary），所有 fill 時間皆為整點倍數，
確保 oracle key 的 `roundUpToHour()` 計算結果可預測，不同訂單的 oracle key 互相獨立。

---

## Oracle Key 隔離設計

```
A: keccak(T0+0H,  T0+12H)  ← setPrice → A settles
C: keccak(T0+1H,  T0+13H)  ← no setPrice → C refunds only
B: keccak(T0+13H, T0+25H)  ← setPrice → B ready to settle from UI
D: keccak(T0+25H, T0+37H)  ← no setPrice → D pending
```

四個 oracle key 完全不同，setPrice 操作不互相影響。

---

## Script 執行順序

```
T0+0H   deploy contracts
        mint & approve tokens
        fill(A)                          → tradeId A
T0+1H   fill(C)                          → tradeId C
T0+13H  setPrice(oracle, A.start, A.end) → A oracle ready
        settle(A)                        → A: Settled ✓
        fill(B)                          → tradeId B
T0+25H  fill(D)                          → tradeId D
T0+38H  setPrice(oracle, B.start, B.end) → B oracle ready (not settling)
        ← 凍結，四種狀態同時存在 ✓
```

執行完後 VTN 狀態凍結，四種狀態同時存在於同一條鏈上。

---

## 最終狀態驗證

| 訂單 | 說明 |
|------|------|
| A (Settled) | `settle()` 已呼叫 at T0+13H ✓ |
| B (Ready to Settle) | endTime=T0+25H 已過，oracle price 已設，`settle()` 未呼叫，grace 到 T0+49H 尚未過期 ✓ |
| C (Ready to Refund) | endTime=T0+13H 已過，無 oracle price，grace 到 T0+37H 已在凍結時間 1H 前過期 ✓ |
| D (Pending) | endTime=T0+37H 剛於凍結時間 1H 前過期，無 oracle price，grace 到 T0+61H 尚未過期 ✓ |

---

## 提交產出

- **Tenderly Explorer Link**：包含合約部署 + 所有 tx 歷史
- **GitHub**：`scripts/demo-vtn.sh`
- **文件**：本文件（架構說明 + 操作步驟）

---

## 未來計畫

Order D / C 涉及更完整的合約邏輯（grace period、refund 機制），已納入本次 demo 展示。
後續可考慮擴充：

- 多 maker 帳號場景
- 真實 VWAP 價格（整合 `simulate-and-forward.sh`）
- UI 一鍵連動 demo
