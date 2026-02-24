# Contract Migration: Old → New

> **用途**：作為後續調整 CRE Workflow ↔ 合約 interface 的參考。
> 新合約從 `vwap-rfq-spot` 搬入，**內容未做任何修改**。

---

## 1. 檔案變動

| 舊合約（已刪除） | 新合約 | 說明 |
|---|---|---|
| `src/VWAPSettlement.sol` | `src/ChainlinkVWAPAdapter.sol` | CRE 報告接收器，角色相同但 interface 不同 |
| `src/ReserveManager.sol` | — | 原始 CRE template，已不需要 |
| `src/BalanceReader.sol` | — | 範本工具，已移除 |
| `src/MessageEmitter.sol` | — | 範本工具，已移除 |
| `src/IERC20.sol` | — | 改用 OpenZeppelin IERC20 |
| `src/keystone/` | — | keystone interface 目錄，已移除 |
| — | `src/IVWAPOracle.sol` | 新增：VWAPRFQSpot ↔ Adapter 的 interface |
| — | `src/VWAPRFQSpot.sol` | 新增：主要 RFQ 交易合約（fill / settle / refund） |

---

## 2. 最關鍵的 Interface 差異：`onReport`

這是整合 CRE Workflow 時**最需要調整的地方**。

### 舊：`VWAPSettlement`（實作 Chainlink `IReceiver`）

```solidity
// IReceiver interface — CRE Forwarder 呼叫這個 signature
function onReport(bytes calldata metadata, bytes calldata report) external;

// report 解碼格式（UpdateReserves 重用方式）：
// abi.decode(report, (uint256, uint256))
// [0] totalMinted  = orderId      (uint256)
// [1] totalReserve = (startTime << 128) | (endTime << 64) | priceE8
```

### 新：`ChainlinkVWAPAdapter`（自定義 forwarder，非 IReceiver）

```solidity
// 自定義 onReport — 只接受 report bytes，無 metadata
function onReport(bytes calldata report) external;

// report 解碼格式：
// abi.decode(report, (uint256, uint256, uint256))
// [0] startTime  (uint256)
// [1] endTime    (uint256)
// [2] price      (uint256) — USDC per 1 ETH, scaled 1e9
//                            e.g. 2000 USDC/ETH → 2_000_000_000
```

---

## 3. Report Encoding 差異

| 欄位 | 舊 VWAPSettlement | 新 ChainlinkVWAPAdapter |
|---|---|---|
| **Signature** | `onReport(bytes, bytes)` | `onReport(bytes)` |
| **Key** | `orderId`（uint256） | `(startTime, endTime)` hash |
| **Price field** | `priceE8`（uint64, 8 decimals） | `price`（uint256, 1e9 precision）|
| **Encoding** | packed bits in single uint256 | 3 separate abi-encoded uint256 |
| **Rounding** | 無 | startTime/endTime 自動 round up to hour |

---

## 4. 需要調整的地方（待辦）

### 4.1 CRE Workflow → `onReport` signature ✅ 已修改

**原因**：CRE Forwarder 呼叫的是 `IReceiver.onReport(bytes metadata, bytes report)`，
但原始 `ChainlinkVWAPAdapter` 只有 `onReport(bytes report)`，不實作 `IReceiver`，無法接收 CRE 報告。

**修改內容**（`src/ChainlinkVWAPAdapter.sol`）：
- 新增 `import` keystone `IReceiver` 和 `IERC165`
- `contract ChainlinkVWAPAdapter` 改為實作 `IReceiver, IVWAPOracle`
- `onReport(bytes calldata report)` 改為 `onReport(bytes calldata /*metadata*/, bytes calldata report)`
- 新增 `supportsInterface()` 實作 ERC165

**注意**：修改後合約需要重新部署，並重新產生 Go bindings（見 4.4）。

### 4.2 Report 內容格式

Go workflow 端目前輸出格式（`VWAPSettlement` 的 packed bits）需要改為：

```go
// 舊：UpdateReserves 格式
report = abi.encode(orderId, (startTime<<128)|(endTime<<64)|priceE8)

// 新：ChainlinkVWAPAdapter 格式
report = abi.encode(startTime, endTime, price)  // price in 1e9 (e.g. 2_000_000_000)
```

### 4.3 Price Precision

| | 舊 | 新 |
|---|---|---|
| 欄位型別 | `uint64 priceE8` | `uint256 price` |
| 精度 | 8 decimals（1e8）| 1e9（= USDC decimals × 1e3）|
| 範例 2000 USDC/ETH | `200_000_000_000` (2e11) | `2_000_000_000` (2e9) |

> **換算關係**：`price (1e9)` = USDC per ETH × 1e6
> 使用公式：`usdcAmount = ethAmount * price / 1e18`

### 4.4 Key 機制

- 舊：以 `orderId` 為 key，query 時用 `orderId`
- 新：以 `keccak256(roundedStart, roundedEnd)` 為 key，query 時用時間區間

`VWAPRFQSpot.settle()` 呼叫 `oracle.getPrice(trade.startTime, trade.endTime)`，
Adapter 會自動 round up to hour 後查詢，**不需要 orderId**。

---

## 5. 新架構合約關係圖

```
CRE Workflow (DON)
    │
    │ onReport(bytes report)          ← 目前不相容，需調整 (見 4.1)
    ▼
ChainlinkVWAPAdapter
    │  implements IVWAPOracle
    │  getPrice(startTime, endTime) → uint256
    ▼
VWAPRFQSpot.settle(tradeId)
    │  reads trade.startTime, trade.endTime
    │  calls oracle.getPrice(...)
    │  calculates payout with deltaBps
    └─ transfers USDC / WETH to maker & taker
```

---

## 6. 部署參數

### ChainlinkVWAPAdapter

| 參數 | 說明 |
|---|---|
| `_forwarder` | Chainlink CRE Forwarder 地址（需從 workflow 設定取得） |

### VWAPRFQSpot

| 參數 | 說明 | Sepolia 預設 |
|---|---|---|
| `_usdc` | USDC token 地址 | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| `_weth` | WETH token 地址 | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| `_oracle` | ChainlinkVWAPAdapter 地址 | deploy 後填入 |
| `_refundGrace` | 退款等待期（秒） | `604800`（7 天） |
