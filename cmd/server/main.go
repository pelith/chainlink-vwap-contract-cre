// settler HTTP server
//
// Exposes a small HTTP API that bridges CRE workflow simulate → on-chain.
// The backend calls this service from its hourly cron and manual trigger endpoint.
//
// Endpoints:
//   POST /settle          run simulate + forward rawReport on-chain
//   GET  /health          liveness check
//
// POST /settle behaviour:
//   No body (backfill mode):
//     Checks last 12 hourly slots via oracle.getPrice().
//     For each slot with no price: runs cre simulate then sends rawReport.
//     15s delay between each simulate call to avoid exchange rate-limits.
//   Body {"endTime": <unix>} (single mode):
//     Checks oracle for that slot. If price exists returns it immediately.
//     If missing: runs simulate + sends rawReport. No backfill.
//
// Slot definition:
//   endTime   = hourly boundary (floor to hour)
//   startTime = endTime - 12h
//   e.g. now=01:01 → slots at endTime 01:00, 00:00, 23:00, 22:00, ...
//
// Required env vars:
//   RPC_URL                  EVM RPC endpoint (Sepolia or Tenderly VTN)
//   MANUAL_ORACLE_ADDRESS    ManualVWAPOracle contract address
//   DEPLOYER_PRIVATE_KEY     Signs the on-chain transaction
//
// Optional env vars:
//   SETTLER_ADDR                  Listen address (default :8081)
//   FORWARDER_ADDRESS             MockKeystoneForwarder (default 0x15fC... Sepolia mock)
//   CRE_REPO_DIR                  Working dir for `cre workflow simulate` (default .)
//   SETTLER_COOLDOWN_MIN          Rate-limit window in minutes (default 10)
//   SETTLER_SIMULATE_INTERVAL_SEC Delay between simulate calls in seconds (default 15)
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// MockKeystoneForwarder ABI — report(address receiver, bytes rawReport, bytes reportContext, bytes[] signatures)
const forwarderABIJSON = `[{"name":"report","type":"function","inputs":[
	{"name":"receiver","type":"address"},
	{"name":"rawReport","type":"bytes"},
	{"name":"reportContext","type":"bytes"},
	{"name":"signatures","type":"bytes[]"}
]}]`

// ManualVWAPOracle ABI — getPrice(uint256 startTime, uint256 endTime) returns (uint256)
const oracleABIJSON = `[{"name":"getPrice","type":"function","stateMutability":"view","inputs":[
	{"name":"startTime","type":"uint256"},
	{"name":"endTime","type":"uint256"}
],"outputs":[{"name":"","type":"uint256"}]}]`

var (
	rePriceE6 = regexp.MustCompile(`priceE6=(\d+)`)
	reStatus  = regexp.MustCompile(`\bstatus=(\d+)`)
)

type config struct {
	addr             string
	rpcURL           string
	forwarderAddr    common.Address
	oracleAddr       common.Address
	deployerPrivKey  string
	creRepoDir       string
	cooldown         time.Duration
	simulateInterval time.Duration
}

type server struct {
	cfg         config
	mu          sync.Mutex
	lastTrigger time.Time
}

// ---- request / response types ----

type settleRequest struct {
	EndTime *int64 `json:"endTime,omitempty"`
}

// single mode: one slot
type singleResponse struct {
	StartTime      int64  `json:"startTime"`
	EndTime        int64  `json:"endTime"`
	PriceE6        uint64 `json:"priceE6"`
	TxHash         string `json:"txHash,omitempty"`
	AlreadySettled bool   `json:"alreadySettled"`
}

// backfill mode: multiple slots
type slotResult struct {
	StartTime int64  `json:"startTime"`
	EndTime   int64  `json:"endTime"`
	PriceE6   uint64 `json:"priceE6"`
	TxHash    string `json:"txHash"`
}

type slotError struct {
	StartTime int64  `json:"startTime"`
	EndTime   int64  `json:"endTime"`
	Error     string `json:"error"`
}

type backfillResponse struct {
	Checked        int          `json:"checked"`
	AlreadySettled int          `json:"alreadySettled"`
	Settled        []slotResult `json:"settled"`
	Errors         []slotError  `json:"errors,omitempty"`
}

// ---- main ----

func main() {
	cooldownMin := 10
	if v := os.Getenv("SETTLER_COOLDOWN_MIN"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			cooldownMin = n
		}
	}
	simulateIntervalSec := 15
	if v := os.Getenv("SETTLER_SIMULATE_INTERVAL_SEC"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			simulateIntervalSec = n
		}
	}

	cfg := config{
		addr:             getEnv("SETTLER_ADDR", ":8081"),
		rpcURL:           mustEnv("RPC_URL"),
		forwarderAddr:    common.HexToAddress(getEnv("FORWARDER_ADDRESS", "0x15fC6ae953E024d975e77382eEeC56A9101f9F88")),
		oracleAddr:       common.HexToAddress(mustEnv("MANUAL_ORACLE_ADDRESS")),
		deployerPrivKey:  mustEnv("DEPLOYER_PRIVATE_KEY"),
		creRepoDir:       getEnv("CRE_REPO_DIR", "."),
		cooldown:         time.Duration(cooldownMin) * time.Minute,
		simulateInterval: time.Duration(simulateIntervalSec) * time.Second,
	}

	s := &server{cfg: cfg}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /settle", s.handleSettle)
	mux.HandleFunc("GET /health", handleHealth)

	slog.Info("settler server starting",
		"addr", cfg.addr,
		"oracle", cfg.oracleAddr,
		"forwarder", cfg.forwarderAddr,
		"creRepoDir", cfg.creRepoDir,
		"cooldown", cfg.cooldown,
		"simulateInterval", cfg.simulateInterval,
	)
	if err := http.ListenAndServe(cfg.addr, mux); err != nil {
		slog.Error("server failed", "error", err)
		os.Exit(1)
	}
}

// ---- handlers ----

func (s *server) handleSettle(w http.ResponseWriter, r *http.Request) {
	// Rate limit
	s.mu.Lock()
	if wait := s.cfg.cooldown - time.Since(s.lastTrigger); wait > 0 {
		s.mu.Unlock()
		writeJSON(w, http.StatusTooManyRequests, map[string]any{
			"error":         "cooldown active",
			"retryAfterSec": int(wait.Seconds()),
		})
		return
	}
	s.lastTrigger = time.Now()
	s.mu.Unlock()

	var req settleRequest
	if r.Body != nil {
		json.NewDecoder(r.Body).Decode(&req) //nolint:errcheck // body is optional
	}

	// Generous timeout: backfill can run up to 12 simulates × (15s delay + ~60s simulate)
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Minute)
	defer cancel()

	client, err := ethclient.DialContext(ctx, s.cfg.rpcURL)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": fmt.Sprintf("dial rpc: %v", err)})
		return
	}
	defer client.Close()

	if req.EndTime != nil {
		s.handleSingle(w, ctx, client, *req.EndTime)
	} else {
		s.handleBackfill(w, ctx, client)
	}
}

// handleSingle checks one slot and runs simulate if price is missing.
func (s *server) handleSingle(w http.ResponseWriter, ctx context.Context, client *ethclient.Client, endTimeRaw int64) {
	endTime := (endTimeRaw / 3600) * 3600
	startTime := endTime - 12*3600

	slog.Info("single mode", "startTime", startTime, "endTime", endTime)

	existing, err := s.checkPrice(ctx, client, startTime, endTime)
	if err == nil && existing > 0 {
		slog.Info("price already exists", "endTime", endTime, "priceE6", existing)
		writeJSON(w, http.StatusOK, singleResponse{
			StartTime:      startTime,
			EndTime:        endTime,
			PriceE6:        existing,
			AlreadySettled: true,
		})
		return
	}

	priceE6, txHash, err := s.simulateAndSend(ctx, client, startTime, endTime)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, singleResponse{
		StartTime: startTime,
		EndTime:   endTime,
		PriceE6:   priceE6,
		TxHash:    txHash,
	})
}

// handleBackfill checks last 12 hourly slots and fills any missing prices.
func (s *server) handleBackfill(w http.ResponseWriter, ctx context.Context, client *ethclient.Client) {
	now := time.Now().Unix()
	nowHour := (now / 3600) * 3600

	// 12 slots: endTime = nowHour, nowHour-1h, nowHour-2h, ..., nowHour-11h
	// startTime = endTime - 12h (each slot is a 12h VWAP window)
	type slot struct{ start, end int64 }
	slots := make([]slot, 12)
	for i := 0; i < 12; i++ {
		end := nowHour - int64(i)*3600
		slots[i] = slot{start: end - 12*3600, end: end}
	}

	slog.Info("backfill mode", "slots", 12, "newestEnd", slots[0].end, "oldestEnd", slots[11].end)

	// Check all prices upfront
	var missing []slot
	alreadySettled := 0
	for _, sl := range slots {
		price, err := s.checkPrice(ctx, client, sl.start, sl.end)
		if err != nil || price == 0 {
			missing = append(missing, sl)
		} else {
			alreadySettled++
		}
	}

	slog.Info("backfill check done", "alreadySettled", alreadySettled, "missing", len(missing))

	var settled []slotResult
	var errs []slotError

	for i, sl := range missing {
		if i > 0 {
			slog.Info("waiting before next simulate", "delay", s.cfg.simulateInterval, "slot", i+1, "of", len(missing))
			select {
			case <-time.After(s.cfg.simulateInterval):
			case <-ctx.Done():
				errs = append(errs, slotError{StartTime: sl.start, EndTime: sl.end, Error: "context cancelled"})
				continue
			}
		}

		priceE6, txHash, err := s.simulateAndSend(ctx, client, sl.start, sl.end)
		if err != nil {
			slog.Error("slot failed", "startTime", sl.start, "endTime", sl.end, "error", err)
			errs = append(errs, slotError{StartTime: sl.start, EndTime: sl.end, Error: err.Error()})
			continue
		}

		settled = append(settled, slotResult{
			StartTime: sl.start,
			EndTime:   sl.end,
			PriceE6:   priceE6,
			TxHash:    txHash,
		})
	}

	writeJSON(w, http.StatusOK, backfillResponse{
		Checked:        12,
		AlreadySettled: alreadySettled,
		Settled:        settled,
		Errors:         errs,
	})
}

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// ---- core logic ----

// simulateAndSend runs cre simulate then sends rawReport on-chain.
func (s *server) simulateAndSend(ctx context.Context, client *ethclient.Client, startTime, endTime int64) (uint64, string, error) {
	priceE6, err := s.runSimulate(ctx, startTime, endTime)
	if err != nil {
		return 0, "", err
	}
	txHash, err := s.sendReport(ctx, client, startTime, endTime, priceE6)
	if err != nil {
		return 0, "", err
	}
	return priceE6, txHash, nil
}

// checkPrice reads oracle.getPrice(startTime, endTime). Returns 0 if not set.
func (s *server) checkPrice(ctx context.Context, client *ethclient.Client, startTime, endTime int64) (uint64, error) {
	parsedABI, err := abi.JSON(strings.NewReader(oracleABIJSON))
	if err != nil {
		return 0, fmt.Errorf("parse oracle abi: %w", err)
	}
	calldata, err := parsedABI.Pack("getPrice", big.NewInt(startTime), big.NewInt(endTime))
	if err != nil {
		return 0, fmt.Errorf("pack getPrice: %w", err)
	}

	result, err := client.CallContract(ctx, ethereum.CallMsg{
		To:   &s.cfg.oracleAddr,
		Data: calldata,
	}, nil)
	if err != nil {
		return 0, fmt.Errorf("call getPrice: %w", err)
	}
	if len(result) == 0 {
		return 0, nil
	}

	values, err := parsedABI.Unpack("getPrice", result)
	if err != nil {
		return 0, fmt.Errorf("unpack getPrice: %w", err)
	}
	price, ok := values[0].(*big.Int)
	if !ok {
		return 0, fmt.Errorf("unexpected return type from getPrice")
	}
	return price.Uint64(), nil
}

// runSimulate execs `cre workflow simulate` and parses priceE6 from stdout.
func (s *server) runSimulate(ctx context.Context, startTime, endTime int64) (uint64, error) {
	payload := fmt.Sprintf(`{"startTime":%d,"endTime":%d}`, startTime, endTime)

	cmd := exec.CommandContext(ctx, "cre", "workflow", "simulate", "vwap-eth-quote-flow",
		"--non-interactive",
		"--trigger-index", "0",
		"--http-payload", payload,
		"--target", "staging-settings",
	)
	cmd.Dir = s.cfg.creRepoDir

	slog.Info("running cre simulate",
		"startTime", startTime, "endTime", endTime,
		"startUTC", time.Unix(startTime, 0).UTC().Format("2006-01-02 15:04"),
		"endUTC", time.Unix(endTime, 0).UTC().Format("2006-01-02 15:04"),
	)

	out, err := cmd.CombinedOutput()
	if err != nil {
		return 0, fmt.Errorf("cre simulate exited with error: %w\n%s", err, out)
	}

	priceMatch := rePriceE6.FindSubmatch(out)
	statusMatch := reStatus.FindSubmatch(out)

	if priceMatch == nil || statusMatch == nil {
		return 0, fmt.Errorf("could not parse VWAP result from simulate output:\n%s", out)
	}
	if string(statusMatch[1]) != "0" {
		statusMsg := map[string]string{
			"1": "InsufficientSources", "2": "StaleData",
			"3": "DeviationError", "4": "DataNotReady",
		}
		msg := statusMsg[string(statusMatch[1])]
		if msg == "" {
			msg = "Unknown"
		}
		return 0, fmt.Errorf("VWAP status %s (%s) — fail-closed", string(statusMatch[1]), msg)
	}

	priceE6, err := strconv.ParseUint(string(priceMatch[1]), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse priceE6: %w", err)
	}

	slog.Info("simulate result", "priceE6", priceE6, "startTime", startTime, "endTime", endTime)
	return priceE6, nil
}

// sendReport constructs rawReport and sends it to MockKeystoneForwarder.
func (s *server) sendReport(ctx context.Context, client *ethclient.Client, startTime, endTime int64, priceE6 uint64) (string, error) {
	chainID, err := client.ChainID(ctx)
	if err != nil {
		return "", fmt.Errorf("get chain id: %w", err)
	}

	privKey, err := crypto.HexToECDSA(strings.TrimPrefix(s.cfg.deployerPrivKey, "0x"))
	if err != nil {
		return "", fmt.Errorf("parse private key: %w", err)
	}
	from := crypto.PubkeyToAddress(privKey.PublicKey)

	// rawReport: 109 zero bytes + abi.encode(startTime, endTime, priceE6)
	uint256Ty, _ := abi.NewType("uint256", "", nil)
	encArgs := abi.Arguments{{Type: uint256Ty}, {Type: uint256Ty}, {Type: uint256Ty}}
	encoded, err := encArgs.Pack(big.NewInt(startTime), big.NewInt(endTime), new(big.Int).SetUint64(priceE6))
	if err != nil {
		return "", fmt.Errorf("abi encode rawReport payload: %w", err)
	}
	rawReport := append(make([]byte, 109), encoded...)

	// calldata: MockKeystoneForwarder.report(oracleAddr, rawReport, 0x, [])
	parsedABI, err := abi.JSON(strings.NewReader(forwarderABIJSON))
	if err != nil {
		return "", fmt.Errorf("parse forwarder abi: %w", err)
	}
	calldata, err := parsedABI.Pack("report", s.cfg.oracleAddr, rawReport, []byte{}, [][]byte{})
	if err != nil {
		return "", fmt.Errorf("pack calldata: %w", err)
	}

	// Estimate gas with 20% buffer
	gasLimit, err := client.EstimateGas(ctx, ethereum.CallMsg{
		From: from,
		To:   &s.cfg.forwarderAddr,
		Data: calldata,
	})
	if err != nil {
		slog.Warn("gas estimation failed, using fallback", "error", err)
		gasLimit = 300_000
	}
	gasLimit = gasLimit * 12 / 10

	// EIP-1559 fees
	tip, err := client.SuggestGasTipCap(ctx)
	if err != nil {
		return "", fmt.Errorf("suggest gas tip: %w", err)
	}
	head, err := client.HeaderByNumber(ctx, nil)
	if err != nil {
		return "", fmt.Errorf("latest header: %w", err)
	}
	baseFee := head.BaseFee
	if baseFee == nil {
		baseFee = big.NewInt(1e9)
	}
	maxFee := new(big.Int).Add(new(big.Int).Mul(baseFee, big.NewInt(2)), tip)

	nonce, err := client.PendingNonceAt(ctx, from)
	if err != nil {
		return "", fmt.Errorf("get nonce: %w", err)
	}

	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     nonce,
		To:        &s.cfg.forwarderAddr,
		Gas:       gasLimit,
		GasTipCap: tip,
		GasFeeCap: maxFee,
		Data:      calldata,
	})

	signer := types.LatestSignerForChainID(chainID)
	signedTx, err := types.SignTx(tx, signer, privKey)
	if err != nil {
		return "", fmt.Errorf("sign tx: %w", err)
	}
	if err := client.SendTransaction(ctx, signedTx); err != nil {
		return "", fmt.Errorf("send tx: %w", err)
	}

	slog.Info("tx sent", "hash", signedTx.Hash().Hex(), "nonce", nonce, "gas", gasLimit)
	return signedTx.Hash().Hex(), nil
}

// ---- helpers ----

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		slog.Error("required env var not set", "key", key)
		os.Exit(1)
	}
	return v
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
