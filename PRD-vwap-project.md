# PRD



# Contract Based PRD

# VWAP-RFQ Spot PoC Spec (USDC–WETH)

## 0\. 目標與範圍

本合約提供一種延遲結算的現貨交換機制：

*   交易對固定：`USDC` 與 `WETH`
*   maker 以 EIP-712 離線簽名建立訂單（不需上鏈）
*   taker 取得 maker 訂單後可上鏈呼叫 `fill()` 成交並鎖定雙方資金
*   成交後開始計時 **12 小時**，以此 12 小時區間的 **VWAP（Volume Weighted Average Price）** 作為結算價格基準
*   結算時按 maker 訂單的 `deltaBps`（signed bps）調整 VWAP 價格後完成交換
*   若 taker 存入資金不足以吃下 maker 全額 `amountIn`，則 **部分成交**：用完 taker 存入資金即可，剩餘退回 maker
*   若長時間無法結算（例如 oracle 資料不足或太久沒人結算），可在寬限期後 **原路退款**
*   maker 可上鏈以 `orderHash` 逐筆取消未成交訂單，且取消不揭露訂單細節

非目標（PoC 不處理）：

*   槓桿、保證金率、清算、資金費率
*   多交易對、動態 VWAP 長度、鏈上 orderbook
*   batch cancel（未來再做）
* * *

## 1\. 角色與資產

*   Maker：簽名訂單的地址
*   Taker：呼叫 `fill()` 的 `msg.sender`
*   Tokens：
    *   `USDC`（ERC20, 6 decimals）
    *   `WETH`（ERC20, 18 decimals）
*   Oracle source：
    *   抽象介面 `IVWAPOracle`（見 §1.1）
    *   部署時設定 oracle 地址，未來可透過 adapter 接入不同價格來源

### 1.1 Oracle 介面

```plain
interface IVWAPOracle {
    /// @notice 取得指定時間區間的 VWAP
    /// @param startTime 區間起始時間（unix timestamp）
    /// @param endTime 區間結束時間（unix timestamp）
    /// @return price VWAP 價格，以 USDC per 1 ETH 表示（USDC 最小單位，即 6 decimals）
    /// @dev 若資料不足或區間無效，應 revert
    function getPrice(uint256 startTime, uint256 endTime) external view returns (uint256 price);
}
```

Oracle adapter 由外部實作（非本 spec 範圍），採用 offchain 計算 + onchain publish 模式，詳見 Appendix A。
* * *

## 2\. 時間參數

*   `VWAP_WINDOW = 12 hours`
*   `REFUND_GRACE = X`（PoC 建議 7 days；可部署時設定為 immutable/constant）
*   每筆成交會記錄：
    *   `startTime = block.timestamp`（fill 時刻）
    *   `endTime = startTime + VWAP_WINDOW`
* * *

## 3\. 價格定義與 deltaBps

### 3.1 基準價格

定義 VWAP 價格為：

*   `P_vwap = USDC per 1 ETH`（用 WETH 為 base、USDC 為 quote）
*   在合約內呼叫 `oracle.getPrice(startTime, endTime)` 取得 `usdcPerEth`（USDC 的最小單位）

VWAP（Volume Weighted Average Price）計算公式（oracle 內部實作）：

```plain
P_vwap = Σ(price_i × volume_i) / Σ(volume_i)
```

其中 `price_i` 與 `volume_i` 為時間區間內各筆交易的價格與成交量。

### 3.2 delta 調整

`deltaBps` 是 signed int（建議 `int32`）：

*   `P_adj = P_vwap * (10000 + deltaBps) / 10000`
*   需滿足 `10000 + deltaBps > 0`，否則交易無效（`fill` 或 `settle` revert 均可；建議 `fill` 先檢查避免鎖資金後失敗）
* * *

## 4\. 訂單模型（EIP-712）

### 4.1 Order struct

```plain
struct Order {
    address maker;
    bool    makerIsSellETH;   // true: maker sells WETH for USDC; false: maker sells USDC for WETH
    uint256 amountIn;         // amount of token maker sells (maker deposit)
    uint256 minAmountOut;     // minimum amount taker must deposit (opposite token)
    int32   deltaBps;         // signed bps applied to P_vwap (USDC per ETH)
    uint256 salt;             // arbitrary number to make identical orders unique
    uint256 deadline;         // unix timestamp; order invalid after this
}
```

### 4.2 EIP-712 requirements

*   Domain must include:
    *   `name` (e.g., "VWAP-RFQ-Spot")
    *   `version` (e.g., "1")
    *   `chainId`
    *   `verifyingContract`
*   Typehash:
    *   `ORDER_TYPEHASH = keccak256("Order(address maker,bool makerIsSellETH,uint256 amountIn,uint256 minAmountOut,int32 deltaBps,uint256 salt,uint256 deadline)")`

### 4.3 orderHash

`orderHash` 指的是 EIP-712 digest（typed data hash）。

用途：
*   交易 ID（PoC 可直接以 `orderHash` 作 tradeId）
*   防 replay、防重複 fill
*   取消（revoke）用的 key
* * *

## 5\. 鏈上狀態（用掉就是用掉）

合約維護一個「用掉」集合，不區分取消或成交：

```plain
mapping(address => mapping(bytes32 => bool)) public used;
// used[maker][orderHash] == true => this orderHash is no longer fillable (either filled or cancelled)
```

設計目的：
*   `cancelOrderHash(orderHash)` 不需要上鏈 order 細節
*   `fill()` 會檢查 `used[maker][orderHash] == false`，並在轉帳前立刻設為 true
* * *

## 6\. 成交（fill）

### 6.1 介面

```plain
function fill(
    Order calldata order,
    bytes calldata signature,
    uint256 takerAmountIn
) external returns (bytes32 tradeId);
```

### 6.2 驗證條件

必須全部成立：

1. `block.timestamp <= order.deadline`
2. `10000 + order.deltaBps > 0`
3. `takerAmountIn >= order.minAmountOut`
4. 以 EIP-712 驗簽：`ECDSA.recover(orderHash, signature) == order.maker`
5. `used[order.maker][orderHash] == false`

### 6.3 狀態寫入順序（重要）

*   先設 `used[maker][orderHash] = true`（防重入/重播）
*   再進行 `transferFrom` 鎖資金

### 6.4 鎖資金規則

依 `makerIsSellETH` 決定 token：

*   makerIsSellETH = true：
    *   maker 存入 `amountIn` WETH
    *   taker 存入 `takerAmountIn` USDC
*   makerIsSellETH = false：
    *   maker 存入 `amountIn` USDC
    *   taker 存入 `takerAmountIn` WETH

### 6.5 建立 Trade

`tradeId = orderHash`（PoC 最簡）

```plain
enum Status { Open, Settled, Refunded }

struct Trade {
    address maker;
    address taker;
    bool    makerIsSellETH;
    uint256 makerAmountIn;
    uint256 takerDeposit;
    int32   deltaBps;
    uint64  startTime;
    uint64  endTime;
    Status  status;
}

mapping(bytes32 => Trade) public trades;
```

### 6.6 事件

*   `Filled(maker, taker, orderHash, startTime, endTime, makerAmountIn, takerDeposit, makerIsSellETH, deltaBps)`
* * *

## 7\. 結算（settle）

### 7.1 介面

```plain
function settle(bytes32 tradeId) external;
```

### 7.2 條件

*   `trades[tradeId].status == Open`
*   `block.timestamp >= endTime`

若 `block.timestamp >= endTime + REFUND_GRACE`，本 spec 建議：
> **`settle()`** **直接 revert，改走** **`refund()`**。

### 7.3 VWAP 查詢

呼叫 oracle 取得結算價格：

```plain
uint256 usdcPerEth = oracle.getPrice(trade.startTime, trade.endTime);
uint256 P_adj = usdcPerEth * uint256(int256(10000) + trade.deltaBps) / 10000;
```

若 `oracle.getPrice()` revert（例如資料不足），`settle()` 也會 revert，等待稍後重試或走 refund。

### 7.4 交換與部分成交

使用 `P_adj` 做結算。整體規則：

*   以 maker 存入的 `makerAmountIn` 為目標成交量
*   若 taker deposit 不足以全額吃下 maker，則用完 taker deposit，剩餘退回 maker
*   多餘的 taker deposit 也必須退回

#### Case A：maker 賣 WETH（WETH → USDC）

*   makerDeposit = `makerEth`（WETH）
*   takerDeposit = `takerUsdc`（USDC）

計算：
*   `ethUsed = min(makerEth, floor(takerUsdc * 1e18 / P_adj))`
*   `usdcPaid = floor(ethUsed * P_adj / 1e18)`

轉帳：
*   maker 收 `usdcPaid`
*   taker 收 `ethUsed`

退款：
*   maker 退 `makerEth - ethUsed`
*   taker 退 `takerUsdc - usdcPaid`

#### Case B：maker 賣 USDC（USDC → WETH）

*   makerDeposit = `makerUsdc`
*   takerDeposit = `takerEth`

計算：
*   `usdcUsed = min(makerUsdc, floor(takerEth * P_adj / 1e18))`
*   `ethPaid = floor(usdcUsed * 1e18 / P_adj)`

轉帳：
*   maker 收 `ethPaid`
*   taker 收 `usdcUsed`

退款：
*   maker 退 `makerUsdc - usdcUsed`
*   taker 退 `takerEth - ethPaid`

完成後：
*   `trade.status = Settled`
*   emit `Settled(tradeId, usdcPerEth, P_adj, makerPayout, takerPayout, makerRefund, takerRefund)`
* * *

## 8\. 退款（refund）

### 8.1 介面

```plain
function refund(bytes32 tradeId) external;
```

### 8.2 條件

*   `trade.status == Open`
*   `block.timestamp >= endTime + REFUND_GRACE`

### 8.3 行為

原路退回雙方存入資金：

*   maker 取回 `makerAmountIn`（原 token）
*   taker 取回 `takerDeposit`（原 token）

狀態：
*   `trade.status = Refunded`
*   emit `Refunded(tradeId, makerRefund, takerRefund)`
* * *

## 9\. 取消（cancel）

### 9.1 介面

```plain
function cancelOrderHash(bytes32 orderHash) external;
```

### 9.2 行為

*   檢查 `used[msg.sender][orderHash] == false`
*   設 `used[msg.sender][orderHash] = true`
*   emit `Cancelled(msg.sender, orderHash)`

特性：
*   不需提供 `Order` payload
*   不會在鏈上暴露訂單內容（未成交單仍可保持私密）
* * *

## 10\. 安全與工程約束（PoC 必要最低限度）

*   `fill/settle/refund/cancel` 需 `nonReentrant`
*   使用 `SafeERC20`（處理不標準 ERC20）
*   使用 `mulDiv`（512-bit）避免 overflow 與精度錯誤
*   `fill()` 建議先寫入 `used` 再轉帳
*   Oracle 可能因資料不足而 revert：
    *   在 refund grace 前：`settle()` revert 讓人之後再試
    *   超過 grace：允許 `refund()`
* * *

## 11\. 建議的 Errors（可用 custom error）

*   `ExpiredOrder()`
*   `BadSignature()`
*   `OrderUsed()`
*   `DeltaInvalid()`
*   `TakerTooSmall()`
*   `TradeNotOpen()`
*   `NotMatured()`
*   `RefundNotAvailable()`
*   `OracleFailed()`（oracle revert 時）
*   `TooLateToSettle()`（若採用「超過 grace 禁止 settle」）
* * *

## 12\. 最小可測試案例（MVP test plan）

1. 正常：maker 賣 WETH、taker 足額，12h 後 settle 全額成交
2. 部分成交：maker 賣 WETH、taker USDC 不足，只成交部分，雙方正確退款
3. 另一方向：maker 賣 USDC、taker WETH 足額/不足（各一）
4. delta 正負：`deltaBps` 為正/負，`P_adj` 正確作用
5. deadline 過期：fill revert
6. cancel：maker cancel hash 後，fill 同一 orderHash revert
7. refund：過 `endTime + grace` 後可 refund，並且 settle 不再允許成功（若採用 TooLateToSettle）
8. oracle 失敗：mock oracle revert，驗證 settle revert 但 refund 仍可在 grace 後執行
* * *

## Appendix A: Oracle 架構說明

### A.1 設計理念

VWAP 需要完整的交易量與價格資料，這類計算在鏈上執行成本過高且資料難以取得。因此本 spec 採用 **offchain 計算 + onchain publish** 的模式：

1. **Offchain**：Oracle provider 從 CEX / DEX 聚合交易資料，計算指定時間區間的 VWAP
2. **Onchain**：將計算結果連同證明（signature / merkle proof）發布到鏈上
3. **Query**：合約透過 `IVWAPOracle.getPrice(startTime, endTime)` 查詢已發布的資料

### A.2 潛在 Oracle Provider

*   **Chainlink Data Feeds / Functions**
    *   使用 Chainlink Functions 呼叫 offchain API 計算 VWAP
    *   或等待 Chainlink 推出原生 VWAP feed
*   **Pyth Network**
    *   Pyth 提供高頻價格更新，可在 offchain 聚合計算 VWAP 後 publish
    *   適合需要細粒度價格資料的場景
*   **Custom Oracle with Attestation**
    *   自建 oracle 服務，offchain 計算 VWAP
    *   使用多簽或 TEE attestation 確保資料可信度
    *   最大彈性，但需自行處理信任模型

### A.3 Adapter 實作要點

```plain
contract ChainlinkVWAPAdapter is IVWAPOracle {
    // 儲存已 publish 的 VWAP 資料
    // key: keccak256(abi.encode(startTime, endTime))
    mapping(bytes32 => uint256) public publishedPrices;

    function getPrice(uint256 startTime, uint256 endTime)
        external view returns (uint256 price)
    {
        bytes32 key = keccak256(abi.encode(startTime, endTime));
        price = publishedPrices[key];
        if (price == 0) revert OracleDataNotAvailable();
    }

    // 由 oracle operator 呼叫，發布 VWAP 資料
    function publishPrice(
        uint256 startTime,
        uint256 endTime,
        uint256 price,
        bytes calldata proof  // signature or other attestation
    ) external {
        // 驗證 proof...
        bytes32 key = keccak256(abi.encode(startTime, endTime));
        publishedPrices[key] = price;
    }
}
```

### A.4 時間區間對齊

為簡化 oracle 運營，建議將結算時間區間對齊到固定邊界（如每小時整點），減少需要 publish 的資料組合數量。此為 adapter 層的優化，不影響核心合約邏輯。

# Frontend PRD

# VWAP-RFQ Spot 前端產品 PRD v2.1
## 一、產品目標

建立一個基於 VWAP 延遲結算機制的 RFQ 交易前端介面，使用者能夠：

1. Maker 建立並管理報價
2. Taker 查看並吃單
3. 雙方查看鎖倉與結算狀態
4. 清楚理解延遲定價機制與部分成交邏輯
5. 控制授權風險與資金暴露

* * *

## 二、核心概念與術語規範
### 2.1 關鍵術語定義

| Contract 參數 | 本質 | Maker 視角 | Taker 視角 | UI 顯示術語 |
| ---| ---| ---| ---| --- |
| `amountIn` | Maker 賣出量 | 我要賣的量 | Maker 出售量 | 「賣出 10 WETH」 |
| `minAmountOut` | Taker 最低存入量 | 對方至少要拿這麼多來換 | 入場門檻/最低抵押 | 「需存入 ≥ 25,000 USDC」 |
| `takerAmountIn` | Taker 實際存入 | \- | 我要存入的量 | 「你存入 30,000 USDC」 |
| `deltaBps` | 價格調整（signed bps） | 溢價/折價設定 | 價格調整 | 「+50 bps (+0.5%)」 |
| VWAP 結算 | 實際成交金額 | 我最終收到的 | 我最終付出的 | 「成交 25,500 USDC」 |

### 2.2 minAmountOut 的本質
**不是「成交金額」，而是「入場門檻」或「最低抵押金額」**
核心概念：
*   Taker 必須存入至少這麼多資金才能參與交易（類似擔保金）
*   實際成交金額由 VWAP 決定，可能遠小於存入金額
*   未用完的資金會在結算時退回 Taker

設計目的：
*   防止報價被小額成交騷擾
*   確保交易有經濟意義（Gas 成本合理）
*   提高 Taker 認真度

範例說明：
*   Maker 賣 10 WETH，設定 minAmountOut = 25,000 USDC
*   Taker 存入 30,000 USDC → 符合門檻，允許 fill
*   VWAP 結算後實際用掉 25,500 USDC → 剩餘 4,500 USDC 退回 Taker
*   若 Taker 存入 20,000 USDC → 不符合門檻，fill 交易失敗
*   **不會影響實際成交價格**

### 2.3 中英文術語對照表
#### 交易流程

| 中文 | English | 說明 |
| ---| ---| --- |
| 報價 | Quote / Order | Maker 建立的訂單 |
| 成交 / 吃單 | Fill | Taker 執行報價 |
| 鎖倉 | Lock / Locking | 資金鎖定期間 |
| 結算 | Settle / Settlement | 12 小時後依 VWAP 完成交易 |
| 退款 | Refund | 超過寬限期後原路退回 |

#### 金額與價格

| 中文 | English | Contract 參數 |
| ---| ---| --- |
| 最低抵押 / 入場門檻 | Minimum Collateral / Entry Threshold | `minAmountOut` |
| 存入金額 | Taker Amount In | `takerAmountIn` |
| 價格調整 / 溢折價 | Delta | `deltaBps` |
| 成交量加權均價 | VWAP | Volume Weighted Average Price |

#### 時間相關

| 中文 | English | Contract 參數 |
| ---| ---| --- |
| 寬限期 | Grace Period | `REFUND_GRACE` |
| VWAP 時間窗口 | VWAP Window | `VWAP_WINDOW` (12H) |

#### 狀態

| 中文 | English | Contract Status |
| ---| ---| --- |
| 已成交 | Filled | \- |
| 已取消 | Cancelled | \- |
| 鎖倉中 | Locking | `Open` (未到 endTime) |
| 可結算 | Ready to Settle | `Open` (已到 endTime) |
| 已結算 | Settled | `Settled` |
| 可退款 | Refundable | `Open` (超過 grace) |
| 已退款 | Refunded | `Refunded` |

#### 其他技術術語

| 中文 | English | 說明 |
| ---| ---| --- |
| 授權額度 | Allowance | ERC20 授權額度 |
| 報價 ID / 交易 ID | Order Hash / Trade ID | `orderHash` |
| 部分成交 | Partial Fill | Taker 資金不足以全額吃下 |
| 基點 | Basis Points (bps) | 1 bps = 0.01% |

### 2.4 部分成交機制
**關鍵原則：以 Maker 的** **`amountIn`** **為目標，但受限於 Taker 實際存入金額**

運作邏輯：
1. Taker 存入 `takerAmountIn`（必須 ≥ `minAmountOut`）
2. 等待 12 小時取得 VWAP
3. 結算時計算實際能成交多少
4. 若 Taker 存入不足以全額吃下 Maker，則部分成交
5. 多餘的資金退回給雙方

計算邏輯（Maker 賣 WETH 為例）：
*   以 Taker 存入的 USDC 除以調整後價格，計算可買多少 WETH
*   取 min(Maker 的 amountIn, 計算出的 WETH 數量)
*   未用完的 USDC 退回 Taker，未賣出的 WETH 退回 Maker
* * *
## 三、資訊架構
### 3.1 導航結構
*   **Market** - 報價列表（Taker 視角）
*   **My Quotes** - 報價管理（Maker 視角）
*   **My Trades** - 鎖倉與結算（雙方視角）
*   **Wallet** - 連接錢包與授權管理
* * *

## 四、Market 頁面（報價列表）
### 4.1 Quote Card 必要資訊
每張報價卡片需顯示：
1. **交易方向與數量**
    *   範例：「賣出 10 WETH」或「賣出 20,000 USDC」
2. **成交規則（deltaBps）**
    *   表達方式：「成交價 = 未來 12H VWAP × (1 + 0.5%)」
    *   技術細節可選在 tooltip：「deltaBps: +50 bps」
3. **入場門檻**
    *   表達方式：「需存入 ≥ 25,000 USDC」
    *   附加說明：「實際成交金額由 VWAP 決定，多存的金額會退回」
4. **有效時間**
    *   倒數計時顯示
5. **操作按鈕**
    *   View（查看詳情）
    *   Fill（直接吃單）

### 4.2 Quote 詳情頁
#### 必要資訊區塊
**市場參考資訊**：
*   當前即時價格
*   過去 12H 均價
*   本報價的價格調整（deltaBps）
*   警告文字：「以上為歷史參考，實際成交價格將依未來 12 小時 VWAP 計算」
**deltaBps 說明**：
*   解釋成交價計算公式
*   說明正值/負值的意義（對誰有利）
**部分成交說明**：
*   說明 Taker 存入金額可能無法全額吃下 Maker 報價
*   提供計算範例

### 4.3 Fill Modal
#### 必要元件
**輸入欄位**：
*   Taker 存入金額輸入框
*   顯示最低門檻、建議金額、用戶餘額
**重要提示**：
*   資金將鎖定 12 小時
*   實際成交金額取決於 VWAP
*   多存的金額會退回
**範例計算**：
*   幫助用戶理解部分成交機制
**操作按鈕**：
*   若 allowance 不足 → 顯示 Approve 按鈕
*   若 allowance 足夠 → 顯示 Fill 按鈕
* * *

## 五、My Quotes 頁面（Maker 管理）
### 5.1 Tab 分類
*   Active - 進行中的報價
*   Filled - 已被成交
*   Cancelled - 已取消
*   Expired - 已過期

### 5.2 報價列表顯示
每列需顯示：
*   交易方向與數量
*   價格調整（deltaBps）
*   最低抵押門檻
*   到期倒數
*   狀態
*   操作按鈕（Active 狀態提供 Cancel）

### 5.3 過期處理
當 `block.timestamp > order.deadline` 時：
*   前端自動將報價從 Active 移至 Expired tab
*   顯示「已過期，無法再被成交」狀態

註：此為前端 UI 優化，contract 會在 fill 時檢查 deadline

### 5.4 授權風險監控面板
#### 顯示資訊
*   已授權額度（Allowance）
*   活躍報價總額（Active Quotes Total）
*   可同時成交上限：min(balance, allowance)
*   風險狀態進度條

#### 風險等級
*   < 60% → 安全（綠色）
*   60% ~ 90% → 注意（黃色）

> 90% → 高風險（紅色）

#### 警告提示
「若多筆報價同時成交，可能因授權或餘額不足導致部分交易失敗」

#### 操作
提供「提高授權額度」按鈕
* * *

## 六、My Trades 頁面（鎖倉與結算）
### 6.1 Tab 分類
*   Locking - 鎖倉中（未到結算時間）
*   Ready to Settle - 可結算（已到 endTime）
*   Settled - 已結算
*   Refundable - 可退款（超過 grace period）
*   Refunded - 已退款

### 6.2 Trade 顯示資訊
每筆交易需顯示：
*   角色（Maker / Taker）
*   存入資產
*   預期獲得資產
*   開始時間
*   結束時間
*   當前狀態
*   操作按鈕

### 6.3 Locking 狀態
顯示資訊：
*   Trade ID
*   結算進度條（X / 12 小時）
*   剩餘時間
*   說明文字：「成交價格將於 12 小時後確定」

### 6.4 Settle 與 Refund 操作
#### Ready to Settle（已到 endTime，未超過 grace）
*   顯示「已達結算時間」
*   提供 Settle 按鈕
*   點擊後呼叫 `settle(tradeId)`
*   若成功 → 顯示成交結果
*   若失敗 → 顯示錯誤訊息

#### Refundable（超過 endTime + grace period）
*   顯示「已超過寬限期（7 天）」
*   說明：超過寬限期後 Settle 不再可用，**雙方**可取回原始存入資金
*   提供 Refund 按鈕
*   點擊後呼叫 `refund(tradeId)`

### 6.5 Oracle 失敗處理
若 `settle()` 交易失敗，顯示錯誤訊息：
可能原因：
*   Oracle 價格資料尚未發布（請稍後重試）
*   網路擁堵（增加 Gas 重試）
*   合約狀態異常（請聯繫技術支援）
建議操作：
*   等待後重試 Settle
*   若長時間無法結算，可在 7 天後使用 Refund
技術實作：
*   捕捉 contract revert 錯誤
*   解析 error message（如 `OracleFailed()`）
*   顯示對應的用戶友善提示

### 6.6 時間軸說明

```css
Fill 時刻 ──> 12H 後 ──────────> 7 天後
  ↓            ↓                  ↓
startTime    endTime        endTime + grace

[─Locking──][─Ready to Settle─][─Refundable─]
```

UI 狀態轉換：
1. 0 ~ 12H：Locking tab
2. 12H ~ 7 天：Ready to Settle tab

> 7 天：Refundable tab

註：grace period 預設 7 天，實際值由 contract 部署時決定
* * *
## 七、Maker Console（建立報價）
### 7.1 表單欄位
#### 1\. 交易方向
*   選項：賣出 WETH 換 USDC / 賣出 USDC 換 WETH
#### 2\. 賣出數量（amountIn）
*   輸入框
#### 3\. 價格調整（deltaBps）
*   輸入框（bps 為單位）
*   說明：「成交價 = 未來 12H VWAP × (1 + deltaBps/10000)」
*   建議範圍：-100 ~ +100 bps（-1% ~ +1%）
*   正值對 Maker 有利，負值對 Taker 有利

#### 4\. 最低 Taker 存入量（minAmountOut）
**說明文字**：
*   「Taker 必須至少存入這麼多資金才能成交你的報價」
**設定目的**：
*   防止小額成交騷擾
*   確保交易有經濟意義
*   提高 Taker 認真度
**重要提醒**：
*   這不是最終成交金額
*   最終成交金額由 VWAP 決定
*   Taker 多存的錢會退回
**智能建議功能**：
*   根據 amountIn、當前市價、deltaBps 自動計算建議值
*   計算公式：`suggestedMin = amountIn × 當前市價 × (1 + deltaBps/10000) × 0.3`
**驗證規則**：
*   若 < 建議值 × 0.5 → 警告：門檻過低，可能被小額騷擾
*   若 > 建議值 × 2 → 警告：門檻過高，可能沒人成交

#### 5\. 有效期限（deadline）
*   預設選項：1 小時 / 6 小時 / 24 小時 / 7 天
*   或自定義時間

#### 6\. Salt
*   自動產生，用戶不可見

### 7.2 操作流程
1. 填寫表單
2. 預覽報價
3. 簽名訂單（Sign Order）
4. 顯示 orderHash
5. 發布報價（若有 backend）或複製簽名（若純前端）
* * *

## 八、建議的 UI 元件
### 8.1 Transaction Status Toast
全域提示訊息，用於顯示交易狀態：
*   Approve 進行中 / 成功
*   Fill 進行中 / 成功（顯示 TradeID）
*   Settle 成功（顯示收到金額）
*   Cancel 成功

### 8.2 Price Reference 區塊
在 Quote 詳情頁顯示：
*   當前即時價格
*   過去 12H 均價
*   本報價價格調整
*   預期成交價範圍（標註為「未知」）
*   警告文字：「以上為歷史參考，實際成交價格將依未來 12 小時 VWAP 計算」
* * *

## 九、Cancel 功能
### 9.1 操作流程
在 My Quotes - Active tab：
1. 點擊 Cancel 按鈕
2. 彈出確認 Modal，顯示：
    *   報價資訊
    *   orderHash
    *   取消後的效果說明
    *   注意事項：已被 Fill 的報價無法取消
3. 確認後執行 `cancelOrderHash(orderHash)`

### 9.2 特性說明
*   不需提供完整 Order payload
*   不會在鏈上暴露訂單細節（隱私保護）
*   需支付 Gas 費用

### 9.3 狀態更新
取消成功後：
*   報價從 Active tab 移至 Cancelled tab
*   顯示取消時間
* * *

## 十、可能優化空間（非 MVP）
*   價格歷史圖表（K 線、成交量）, 預留 12 小時空白區間標記為settle time.
*   自動結算 UI 提示）
*   指定 Taker 模式（私密報價）
*   實時 VWAP 計算顯示（教育用途）
* * *

## 十一、核心設計原則
1. 不誤導價格確定性（清楚表達「未來 VWAP」）
2. 清楚表達延遲結算機制（12 小時鎖倉）
3. 清楚分離 Quote 與 Trade 概念
4. 提供 Maker 風險控制視角（Risk Panel）
5. 充分說明部分成交邏輯（避免用戶誤解）
6. 術語一致性（minAmountOut = 最低抵押/入場門檻）
* * *

## 十二、用戶教育重點
### 13.1 常見誤解與澄清
**誤解 1**：「minAmountOut 是我會收到的錢」
*   正確：minAmountOut 是 Taker 的入場門檻，你最終收到多少取決於 VWAP 和 Taker 實際存入金額

**誤解 2**：「Taker 存入 100,000，我就能拿走 100,000」
*   正確：系統會按 VWAP 結算，只用掉實際需要的金額，剩餘退回 Taker

**誤解 3**：「設 minAmountOut 越高我賺越多」
*   正確：設太高會導致沒人來 fill，設太低會被小額騷擾，需要平衡

**誤解 4**：「deltaBps 是固定價格」
*   正確：deltaBps 是對 VWAP 的調整，最終價格取決於未來 12 小時市場

### 12.2 使用引導
建議在用戶進入各頁面時, 可自動或手動觸發顯示引導提示：

**Market 頁面**：
*   說明延遲結算機制：成交後鎖倉 12 小時，價格由未來 VWAP 決定
*   部分成交會退回多餘資金

**My Quotes 頁面**：
*   minAmountOut 用途說明
*   deltaBps 意義說明
*   提醒監控授權風險面板

**My Trades 頁面**：
*   交易流程說明：Fill → Locking (12H) → Settle → 完成
*   超過 7 天可 Refund
* * *

## 十四、技術實作建議

### 14.1 前端狀態管理
建議使用狀態機管理 Trade 生命週期：

```yaml
Trade States:
- LOCKING: startTime ≤ now < endTime
- READY: endTime ≤ now < endTime + grace
- REFUNDABLE: now ≥ endTime + grace
- SETTLED: status == Settled (onchain)
- REFUNDED: status == Refunded (onchain)
```

### 14.2 智能建議計算

```javascript
// minAmountOut 智能建議
function suggestMinAmountOut(
  amountIn,
  currentPrice,
  deltaBps,
  makerIsSellETH
) {
  const P_adj = currentPrice * (1 + deltaBps / 10000);

  if (makerIsSellETH) {
    return amountIn * P_adj * 0.3; // 建議 30% 保守門檻
  } else {
    return (amountIn / P_adj) * 0.3;
  }
}
```

### 14.3 錯誤處理優先級
**Critical（阻斷操作）**：
*   Deadline 已過期
*   餘額不足
*   Allowance 不足

**Warning（可繼續但需確認）**：
*   minAmountOut 過低/過高
*   Gas 價格異常
*   授權風險 > 90%

**Info（提示訊息）**：
*   Oracle 價格更新延遲
*   網路擁堵
*   交易待確認
* * *

## 十五、測試場景
### 15.1 Maker 流程
*   建立報價（正常、過期、無效 deltaBps）
*   取消報價（已用掉的無法取消）
*   授權風險警告觸發
*   智能建議正確計算

### 15.2 Taker 流程
*   Fill 報價（全額成交）
*   Fill 報價（部分成交）
*   Fill 低於 minAmountOut（應失敗）
*   Approve → Fill 流程

### 15.3 結算流程
*   Settle 成功（全額/部分成交）
*   Settle 失敗（Oracle 未準備好）
*   Refund（超過 grace period）
*   狀態轉換（Locking → Ready → Settled）
* * *

## 十六、附錄：Contract 關鍵參數對照

| Contract | Frontend Display | 範例 |
| ---| ---| --- |
| `VWAP_WINDOW` | 12 小時鎖倉期 | Locking 進度條 |
| `REFUND_GRACE` | 7 天寬限期 | Refundable 說明 |
| `deltaBps` | +50 bps (+0.5%) | Quote Card 價格調整 |
| `orderHash` | 報價 ID / Trade ID | 0x1234...5678 |
| `used[maker][orderHash]` | 已取消/已成交 | Cancelled/Filled tab |

* * *

**PRD v2.1 結束**

_最後更新：2025-02-11_
_作者： Tim Wang_

# Backend PRD

# VWAP-RFQ Spot 後端 PRD v1

## 變更記錄
*   v1 (2025-02-12): 初版，定義核心服務與 API 規格
* * *

## 一、產品目標

提供 VWAP-RFQ Spot 協議的後端服務，支援：

1. 報價管理 - 儲存和查詢 Maker 的離線簽名訂單
2. 狀態同步 - 監聽鏈上事件並同步交易狀態
3. 交易記錄 - 提供用戶的交易歷史查詢
4. 價格參考 - 提供市場參考價格（實作方式待定）
* * *

## 二、系統架構概覽

```java
Frontend
   ↓
Backend API (本文件範圍)
   ↓
PostgreSQL
   ↓
Smart Contract (監聽 Events)
```

後端角色：
*   作為 Orderbook（儲存離線簽名訂單）
*   作為 Indexer（同步鏈上狀態）
*   作為 API Server（提供查詢介面）
* * *

## 三、核心服務

### 3.1 Orderbook Service

#### 職責

管理 Maker 的離線簽名訂單：
*   接收並儲存簽名訂單
*   提供報價查詢（支援篩選與分頁）
*   追蹤訂單狀態（Active / Filled / Cancelled / Expired）

#### 關鍵邏輯

**訂單驗證**：
*   驗證 EIP-712 簽名正確性
*   檢查 deadline 是否過期
*   檢查 orderHash 是否已存在

**狀態管理**：
*   Active: 新發布且未過期的訂單
*   Filled: 被 Event Indexer 標記為已成交
*   Cancelled: 被 Event Indexer 標記為已取消
*   Expired: deadline 已過期（由定期任務更新）

**過期處理**：
*   定期掃描（建議每 5 分鐘）
*   將 `deadline < now` 的訂單標記為 Expired
* * *

### 3.2 Event Indexer

#### 職責

監聽 Smart Contract 事件並同步狀態到資料庫。

#### 需要監聽的 Contract Events

根據 Contract Spec，需要監聽以下事件：

**1\. Filled Event**

```go
Filled(
    address indexed maker,
    address indexed taker,
    bytes32 indexed orderHash,
    uint64 startTime,
    uint64 endTime,
    uint256 makerAmountIn,
    uint256 takerDeposit,
    bool makerIsSellETH,
    int32 deltaBps
)
```

**處理邏輯**：
*   在 `orders` 表中將對應的 orderHash 標記為 Filled
*   在 `trades` 表中新增一筆記錄
*   記錄 tradeId (= orderHash)、startTime、endTime、參與者地址等資訊

**2\. Cancelled Event**

```css
Cancelled(
    address indexed maker,
    bytes32 indexed orderHash
)
```

**處理邏輯**：
*   在 `orders` 表中將對應的 orderHash 標記為 Cancelled

**3\. Settled Event**

```markdown
Settled(
    bytes32 indexed tradeId,
    uint256 usdcPerEth,
    uint256 P_adj,
    uint256 makerPayout,
    uint256 takerPayout,
    uint256 makerRefund,
    uint256 takerRefund
)
```

**處理邏輯**：
*   更新 `trades` 表中的狀態為 Settled
*   記錄結算價格、各方收到的金額

**4\. Refunded Event**

```markdown
Refunded(
    bytes32 indexed tradeId,
    uint256 makerRefund,
    uint256 takerRefund
)
```

**處理邏輯**：
*   更新 `trades` 表中的狀態為 Refunded
*   記錄退款金額

#### 實作要求

*   使用 WebSocket 或輪詢監聽事件
*   處理區塊鏈重組（reorg）
*   確保事件處理的冪等性（同一事件多次收到不會重複處理）
*   記錄已處理的區塊高度，重啟後從斷點繼續
* * *

### 3.3 Trade History Service

#### 職責

提供交易記錄查詢功能。

#### 資料來源

從 `trades` 表讀取，該表由 Event Indexer 維護。

#### 狀態計算

Trade 的顯示狀態需要根據時間和鏈上狀態計算：

```diff
狀態邏輯：
- Locking: status == Open && now < endTime
- Ready to Settle: status == Open && now >= endTime && now < endTime + grace
- Refundable: status == Open && now >= endTime + grace
- Settled: status == Settled (鏈上)
- Refunded: status == Refunded (鏈上)
```

註：grace period 預設 7 天，實際值由 Contract 部署時決定
* * *

### 3.4 Price Reference Service

#### 職責

提供市場參考價格，用於前端顯示。

#### 重要說明

**此服務的實作方式尚未確定，需要額外討論以下議題：**

1. **價格來源**
    *   使用哪些交易所的數據？（Binance / Coinbase / Kraken / DEX）
    *   使用 VWAP 還是 TWAP？
    *   計算方式與 Oracle 是否一致？
2. **實作方式**
    *   後端自行計算？
    *   呼叫第三方 API？
    *   讀取鏈上 Oracle？
3. **信任模型**
    *   如何確保價格不被操縱？
    *   是否需要多簽驗證？
    *   如何處理數據來源故障？

#### 暫定 API 介面

在實作方式確定前，先定義 API 介面：

```sql
GET /api/v1/price/current
回傳：當前市場參考價格

GET /api/v1/price/history?hours=12
回傳：過去指定小時數的價格資料
```

**前端使用注意**：
*   標註為「僅供參考」
*   不保證與實際結算價格一致
*   實際結算價格由 Oracle 決定
* * *

## 四、API 規格

### 4.1 Orderbook API

#### POST /api/v1/orders

發布新的報價。

**Request Body**：

```json
{
  "order": {
    "maker": "0x...",
    "makerIsSellETH": true,
    "amountIn": "10000000000000000000",
    "minAmountOut": "25000000000",
    "deltaBps": 50,
    "salt": "12345",
    "deadline": 1707840000
  },
  "signature": "0x..."
}
```

**Response**：

```json
{
  "orderHash": "0x...",
  "status": "active"
}
```

**驗證邏輯**：
1. 驗證 EIP-712 簽名
2. 檢查 deadline 未過期
3. 檢查 orderHash 未被使用
4. 檢查 deltaBps 有效性（10000 + deltaBps > 0）

**錯誤情況**：
*   400: 簽名無效、參數錯誤、訂單已存在
*   500: 伺服器錯誤
* * *

#### GET /api/v1/orders

查詢可用的報價列表。

**Query Parameters**：

```cpp
?makerIsSellETH=true          // 篩選方向（可選）
&status=active                 // 篩選狀態（可選）
&maker=0x...                   // 篩選 maker（可選）
&limit=20                      // 分頁大小（預設 20）
&offset=0                      // 分頁偏移（預設 0）
```

**Response**：

```json
{
  "orders": [
    {
      "orderHash": "0x...",
      "order": {
        "maker": "0x...",
        "makerIsSellETH": true,
        "amountIn": "10000000000000000000",
        "minAmountOut": "25000000000",
        "deltaBps": 50,
        "salt": "12345",
        "deadline": 1707840000
      },
      "signature": "0x...",
      "status": "active",
      "createdAt": "2025-02-12T10:00:00Z"
    }
  ],
  "total": 100,
  "limit": 20,
  "offset": 0
}
```

* * *

#### GET /api/v1/orders/:orderHash

查詢單筆報價。

**Response**：

```json
{
  "orderHash": "0x...",
  "order": { ... },
  "signature": "0x...",
  "status": "active",
  "createdAt": "2025-02-12T10:00:00Z",
  "filledAt": null
}
```

**錯誤情況**：
*   404: 訂單不存在
* * *

### 4.2 Trade API

#### GET /api/v1/trades

查詢交易列表。

**Query Parameters**：

```cpp
?address=0x...                 // 篩選 maker 或 taker（必填）
&status=locking                // 篩選狀態（可選）
&limit=20
&offset=0
```

**Response**：

```json
{
  "trades": [
    {
      "tradeId": "0x...",
      "maker": "0x...",
      "taker": "0x...",
      "makerIsSellETH": true,
      "makerAmountIn": "10000000000000000000",
      "takerDeposit": "25000000000",
      "deltaBps": 50,
      "startTime": 1707840000,
      "endTime": 1707883200,
      "status": "locking",
      "createdAt": "2025-02-12T10:00:00Z"
    }
  ],
  "total": 50,
  "limit": 20,
  "offset": 0
}
```

**status 欄位說明**：
*   `locking`: 鎖倉中（now < endTime）
*   `ready`: 可結算（now >= endTime && status == Open）
*   `refundable`: 可退款（now >= endTime + grace && status == Open）
*   `settled`: 已結算
*   `refunded`: 已退款
* * *

#### GET /api/v1/trades/:tradeId

查詢單筆交易詳情。

**Response**：

```json
{
  "tradeId": "0x...",
  "maker": "0x...",
  "taker": "0x...",
  "makerIsSellETH": true,
  "makerAmountIn": "10000000000000000000",
  "takerDeposit": "25000000000",
  "deltaBps": 50,
  "startTime": 1707840000,
  "endTime": 1707883200,
  "status": "settled",
  "settlementPrice": "2512500000",
  "makerPayout": "25125000000",
  "takerPayout": "10000000000000000000",
  "makerRefund": "0",
  "takerRefund": "0",
  "settledAt": "2025-02-12T22:05:00Z"
}
```

**錯誤情況**：
*   404: 交易不存在
* * *

### 4.3 Price API

#### GET /api/v1/price/current

取得當前市場參考價格。

**Response**：

```json
{
  "price": "2500000000",
  "timestamp": 1707840000,
  "source": "reference",
  "warning": "僅供參考，實際結算價格由 Oracle 決定"
}
```

註：實作細節待 Oracle 方案確定後補充。
* * *

#### GET /api/v1/price/history

取得歷史價格資料。

**Query Parameters**：

```cpp
?hours=12                      // 時間範圍（預設 12）
```

**Response**：

```json
{
  "prices": [
    {
      "price": "2500000000",
      "timestamp": 1707840000
    },
    ...
  ],
  "averagePrice": "2485000000",
  "warning": "僅供參考，實際結算價格由 Oracle 決定"
}
```

註：實作細節待 Oracle 方案確定後補充。
* * *

## 五、錯誤處理

### 5.1 HTTP 狀態碼規範

*   `200 OK`: 請求成功
*   `400 Bad Request`: 請求參數錯誤、簽名無效
*   `404 Not Found`: 資源不存在
*   `429 Too Many Requests`: 請求過於頻繁（如有 rate limiting）
*   `500 Internal Server Error`: 伺服器錯誤
* * *

### 5.2 錯誤格式

所有錯誤回應使用統一格式：

```json
{
  "error": "ERROR_CODE",
  "message": "Human readable error message",
  "details": {
    "field": "additional context"
  }
}
```

* * *

### 5.3 常見錯誤碼

**Orderbook 相關**：
*   `INVALID_SIGNATURE`: EIP-712 簽名驗證失敗
*   `ORDER_EXPIRED`: 訂單已過期（deadline < now）
*   `ORDER_EXISTS`: orderHash 已存在
*   `INVALID_DELTA`: deltaBps 無效（10000 + deltaBps <= 0）
*   `INVALID_AMOUNT`: amountIn 或 minAmountOut 無效

**查詢相關**：
*   `ORDER_NOT_FOUND`: 訂單不存在
*   `TRADE_NOT_FOUND`: 交易不存在
*   `INVALID_PARAMETER`: 查詢參數格式錯誤

**系統相關**：
*   `DATABASE_ERROR`: 資料庫錯誤
*   `BLOCKCHAIN_ERROR`: 區塊鏈連接錯誤
*   `INTERNAL_ERROR`: 內部錯誤
* * *

## 六、Chainlink Automation 整合指南

本節為獨立模組，供團隊調研使用。

### 6.1 Chainlink Automation 簡介

Chainlink Automation（原 Chainlink Keepers）是去中心化的鏈上自動化服務，可以：
*   監控鏈上狀態
*   在條件滿足時自動觸發交易
*   無需自建中心化服務器

在 VWAP-RFQ 中的用途：
*   自動檢測 Trade 是否到期（endTime 到達）
*   自動呼叫 `settle(tradeId)` 完成結算
*   減少用戶手動操作
* * *

### 6.2 Contract 端要求

Smart Contract 需要實作 `AutomationCompatibleInterface`：

```plain
interface AutomationCompatibleInterface {
    // 檢查是否需要執行
    function checkUpkeep(bytes calldata checkData)
        external view
        returns (bool upkeepNeeded, bytes memory performData);

    // 執行自動化任務
    function performUpkeep(bytes calldata performData) external;
}
```

**實作邏輯**：
*   `checkUpkeep`: 掃描所有 Open 狀態且 `endTime <= now` 的 trades
*   `performUpkeep`: 呼叫 `settle(tradeId)` 進行結算
* * *

### 6.3 註冊與配置

**步驟**：
1. 訪問 [Chainlink Automation](https://automation.chain.link/)
2. 連接錢包並選擇網路
3. 註冊新的 Upkeep：
    *   Target Contract: 你的 VWAP-RFQ Contract 地址
    *   Gas Limit: 建議 500,000
    *   Starting Balance: 充值 LINK（建議 5-10 LINK）
    *   Upkeep Name: "VWAP-RFQ Auto Settler"

**配置參數**：
*   Check Interval: 建議 5 分鐘
*   Gas Price Limit: 依網路狀況調整
* * *

### 6.4 監控與維護

**需要監控的指標**：
*   LINK 餘額（低於 2 LINK 時充值）
*   Upkeep 執行次數
*   執行成功/失敗率
*   Gas 消耗情況

**獲取 Upkeep 狀態**：
可透過 Chainlink Automation UI 或 API 查詢：
*   當前餘額
*   最後執行時間
*   執行歷史

**故障處理**：
*   如果 Chainlink Automation 故障，用戶仍可手動呼叫 `settle()`
*   超過 grace period (7 天) 後，用戶可呼叫 `refund()` 取回資金
* * *

### 6.5 成本估算

**Gas 成本**：
*   單次 settle: ~200,000 - 300,000 gas
*   假設 gas price = 20 gwei，ETH = $3,000
*   單次成本 ≈ $12 - $18

**LINK 消耗**：
*   Chainlink Automation 收取 premium
*   實際成本需根據網路和執行頻率評估

**優化建議**：
*   Batch settling（一次處理多筆）
*   使用 L2（Arbitrum/Optimism）降低成本
* * *

### 6.6 與後端的協作

**後端的角色**：
*   監聽 `Settled` event，更新資料庫狀態
*   提供監控 dashboard 顯示自動結算狀態
*   如果 Chainlink Automation 失敗，可在前端提示用戶手動 settle

**不需要後端做的**：
*   後端不需要觸發 settle（由 Chainlink 處理）
*   後端不需要管理 settle 隊列
*   後端不需要支付 gas（由 Chainlink Upkeep 支付）
* * *

### 6.7 參考資源

*   [Chainlink Automation 文檔](https://docs.chain.link/chainlink-automation)
*   [註冊 Upkeep 教學](https://docs.chain.link/chainlink-automation/guides/register-upkeep)
*   [Contract 實作範例](https://docs.chain.link/chainlink-automation/reference/automation-interfaces)
* * *

## 七、術語對照表

### 7.1 核心概念

| 中文 | English | 說明 |
| ---| ---| --- |
| 報價 | Quote / Order | Maker 建立的訂單 |
| 訂單哈希 | Order Hash | EIP-712 typed data hash |
| 成交 / 吃單 | Fill | Taker 執行報價 |
| 交易 ID | Trade ID | 等同於 orderHash |
| 鎖倉 | Lock / Locking | 資金鎖定期間 |
| 結算 | Settle / Settlement | 12 小時後依 VWAP 完成交易 |
| 退款 | Refund | 超過寬限期後原路退回 |
| 成交量加權均價 | VWAP | Volume Weighted Average Price |

### 7.2 API 欄位與 Contract 參數對應

| API 欄位 | Contract 參數 | 類型 | 說明 |
| ---| ---| ---| --- |
| `orderHash` | `orderHash` | bytes32 | 訂單唯一識別符 |
| `maker` | `order.maker` | address | 掛單方地址 |
| `makerIsSellETH` | `order.makerIsSellETH` | bool | true=賣 WETH, false=賣 USDC |
| `amountIn` | `order.amountIn` | uint256 | Maker 賣出數量 |
| `minAmountOut` | `order.minAmountOut` | uint256 | Taker 最低存入量 |
| `deltaBps` | `order.deltaBps` | int32 | 價格調整（signed bps） |
| `salt` | `order.salt` | uint256 | 隨機數（確保唯一性） |
| `deadline` | `order.deadline` | uint256 | 訂單有效期限（unix timestamp） |
| `signature` | `signature` | bytes | EIP-712 簽名 |
| `tradeId` | `tradeId` | bytes32 | 等同於 orderHash |
| `takerDeposit` | `takerAmountIn` | uint256 | Taker 實際存入金額 |
| `startTime` | `trade.startTime` | uint64 | Fill 時刻 |
| `endTime` | `trade.endTime` | uint64 | startTime + 12 小時 |

### 7.3 狀態對應

| API Status | Contract Status | 說明 |
| ---| ---| --- |
| `active` | \- | 訂單未成交且未過期 |
| `filled` | \- | 訂單已被 fill |
| `cancelled` | \- | 訂單已被 cancel |
| `expired` | \- | deadline 已過期 |
| `locking` | `Open` (未到 endTime) | 資金鎖定中 |
| `ready` | `Open` (已到 endTime) | 可以 settle |
| `refundable` | `Open` (超過 grace) | 可以 refund |
| `settled` | `Settled` | 已結算 |
| `refunded` | `Refunded` | 已退款 |

### 7.4 精度規範

| Token | Decimals | 範例 |
| ---| ---| --- |
| USDC | 6 | 1 USDC = 1000000 (API 與 Contract 一致) |
| WETH | 18 | 1 WETH = 1000000000000000000 (API 與 Contract 一致) |

**注意**：API 傳遞的所有金額都是最小單位的字串表示，與 Contract 完全一致。
* * *

## 八、Contract 依賴說明

本 PRD 基於 Contract Spec 編寫，但 Contract 尚在開發中。

### 8.1 假設條件

後端實作假設 Contract 提供以下介面與事件：

**Functions**：
*   `fill(Order calldata order, bytes calldata signature, uint256 takerAmountIn)`
*   `settle(bytes32 tradeId)`
*   `refund(bytes32 tradeId)`
*   `cancelOrderHash(bytes32 orderHash)`

**Events**：
*   `Filled(...)`
*   `Settled(...)`
*   `Refunded(...)`
*   `Cancelled(...)`

**Structs**：
*   `Order { maker, makerIsSellETH, amountIn, minAmountOut, deltaBps, salt, deadline }`
*   `Trade { maker, taker, makerIsSellETH, makerAmountIn, takerDeposit, deltaBps, startTime, endTime, status }`

### 8.2 變動處理

如果 Contract 介面有變動：
*   後端需要更新 Event 監聽邏輯
*   後端需要更新資料結構
*   API 回傳格式可能需要調整

建議：
*   Contract 團隊提前通知介面變動
*   後端預留彈性，使用配置而非硬編碼
*   定期同步 Contract 開發進度
* * *

**PRD v1 結束**

_最後更新：2025-02-12_
_作者：Tim Wang (PM)_

# User flow

[

mermaid.ai

https://mermaid.ai/app/projects/d05f50f8-c00b-48e6-9ed4-6b02bee4341d/diagrams/19761c6c-5b66-4edf-88a6-1c43d87ca2f3/share/invite/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJkb2N1bWVudElEIjoiMTk3NjFjNmMtNWI2Ni00ZWRmLTg4YTYtMWM0M2Q4N2NhMmYzIiwiYWNjZXNzIjoiVmlldyIsImlhdCI6MTc3MDg4NDA1Mn0.JBPsvOwKpnm23RxZRNEmS8G\_xUxtS80ZhxBReYSCVGY

](https://mermaid.ai/app/projects/d05f50f8-c00b-48e6-9ed4-6b02bee4341d/diagrams/19761c6c-5b66-4edf-88a6-1c43d87ca2f3/share/invite/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJkb2N1bWVudElEIjoiMTk3NjFjNmMtNWI2Ni00ZWRmLTg4YTYtMWM0M2Q4N2NhMmYzIiwiYWNjZXNzIjoiVmlldyIsImlhdCI6MTc3MDg4NDA1Mn0.JBPsvOwKpnm23RxZRNEmS8G_xUxtS80ZhxBReYSCVGY)