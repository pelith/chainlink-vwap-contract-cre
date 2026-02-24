# VWAP RFQ Spot — EVM Contracts

## Contracts

| Contract | Description |
|---|---|
| `VWAPRFQSpot.sol` | Main RFQ exchange. Handles `fill` / `settle` / `refund` |
| `ChainlinkVWAPAdapter.sol` | Production oracle. Receives reports from CRE Forwarder |
| `ManualVWAPOracle.sol` | Testing oracle. Owner manually injects prices via `setPrice` |
| `IVWAPOracle.sol` | Interface shared by both oracle implementations |

---

## Setup

Dependencies are managed via Foundry. OpenZeppelin is in `lib/openzeppelin-contracts`.

```bash
# From this directory
forge build
forge test
```

---

## Deploy

All deploy env vars are loaded from `../../.env` automatically.

**Required in `.env`:**
```
DEPLOYER_PRIVATE_KEY=0x...
```

### Manual oracle (testing)

```bash
ORACLE_MODE=manual ./deploy.sh
```

Deploys `ManualVWAPOracle` + `VWAPRFQSpot`. No Chainlink forwarder needed.

### Production (CRE adapter)

```bash
ORACLE_MODE=chainlink ./deploy.sh
```

Also requires:
```
FORWARDER_ADDRESS=0x...   # Chainlink CRE Forwarder address from workflow config
```

---

## Interact — ManualVWAPOracle

After deploying in manual mode, inject a price with `cast`:

```bash
# setPrice(startTime, endTime, price)
# price unit: USDC per 1 ETH scaled by 1e6 (e.g. 2000 USDC/ETH → 2_000_000_000)
cast send <ORACLE_ADDR> \
  "setPrice(uint256,uint256,uint256)" \
  <startTime> <endTime> <price> \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

# Check price is stored
cast call <ORACLE_ADDR> \
  "getPrice(uint256,uint256)(uint256)" \
  <startTime> <endTime> \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## Interact — VWAPRFQSpot

```bash
# Settle a trade (after endTime has passed and oracle price is available)
cast send <SPOT_ADDR> \
  "settle(bytes32)" \
  <tradeId> \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

# Check trade status
cast call <SPOT_ADDR> \
  "getTrade(bytes32)((address,address,bool,uint256,uint256,int32,uint64,uint64,uint8))" \
  <tradeId> \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## Deployed Addresses (Sepolia)

| Contract | Address |
|---|---|
| ManualVWAPOracle | `0x91Da22eD2b7DE3C0132Eba7EdE2826014a24E348` |
| VWAPRFQSpot | `0x3DD3f762d83C13deb95f49CbE5b2bA470003f025` |
