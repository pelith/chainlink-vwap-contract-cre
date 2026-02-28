// settler HTTP server
//
// Exposes a small HTTP API that bridges CRE workflow simulate → on-chain.
// The backend calls this service from its hourly cron and manual trigger endpoint.
//
// Endpoints:
//   POST /settle          run simulate + forward rawReport on-chain
//   GET  /health          liveness check
//
// Required env vars:
//   RPC_URL                  EVM RPC endpoint (Sepolia or Tenderly VTN)
//   MANUAL_ORACLE_ADDRESS    ManualVWAPOracle contract address
//   DEPLOYER_PRIVATE_KEY     Signs the on-chain transaction
//
// Optional env vars:
//   SETTLER_ADDR             Listen address (default :8081)
//   FORWARDER_ADDRESS        MockKeystoneForwarder (default 0x15fC... Sepolia mock)
//   CRE_REPO_DIR             Working dir for `cre workflow simulate` (default .)
//   SETTLER_COOLDOWN_MIN     Rate-limit window in minutes (default 10)
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

var (
	rePriceE6 = regexp.MustCompile(`priceE6=(\d+)`)
	reStatus  = regexp.MustCompile(`\bstatus=(\d+)`)
)

type config struct {
	addr            string
	rpcURL          string
	forwarderAddr   common.Address
	oracleAddr      common.Address
	deployerPrivKey string
	creRepoDir      string
	cooldown        time.Duration
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

type settleResponse struct {
	StartTime int64  `json:"startTime"`
	EndTime   int64  `json:"endTime"`
	PriceE6   uint64 `json:"priceE6"`
	TxHash    string `json:"txHash"`
}

// ---- main ----

func main() {
	cooldownMin := 10
	if v := os.Getenv("SETTLER_COOLDOWN_MIN"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			cooldownMin = n
		}
	}

	cfg := config{
		addr:            getEnv("SETTLER_ADDR", ":8081"),
		rpcURL:          mustEnv("RPC_URL"),
		forwarderAddr:   common.HexToAddress(getEnv("FORWARDER_ADDRESS", "0x15fC6ae953E024d975e77382eEeC56A9101f9F88")),
		oracleAddr:      common.HexToAddress(mustEnv("MANUAL_ORACLE_ADDRESS")),
		deployerPrivKey: mustEnv("DEPLOYER_PRIVATE_KEY"),
		creRepoDir:      getEnv("CRE_REPO_DIR", "."),
		cooldown:        time.Duration(cooldownMin) * time.Minute,
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

	// Parse optional body
	var req settleRequest
	if r.Body != nil {
		json.NewDecoder(r.Body).Decode(&req) //nolint:errcheck // body is optional
	}

	// Compute time window: floor to hour, 12h window
	ref := time.Now().Unix()
	if req.EndTime != nil {
		ref = *req.EndTime
	}
	endTime := (ref / 3600) * 3600
	startTime := endTime - 12*3600

	// Use a generous timeout — cre simulate fetches from 5 exchanges
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Minute)
	defer cancel()

	slog.Info("settle triggered",
		"startTime", startTime,
		"endTime", endTime,
		"startUTC", time.Unix(startTime, 0).UTC().Format("2006-01-02 15:04"),
		"endUTC", time.Unix(endTime, 0).UTC().Format("2006-01-02 15:04"),
	)

	// Step 1: CRE simulate
	priceE6, err := s.runSimulate(ctx, startTime, endTime)
	if err != nil {
		slog.Error("simulate failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	// Step 2: forward rawReport on-chain
	txHash, err := s.sendReport(ctx, startTime, endTime, priceE6)
	if err != nil {
		slog.Error("send report failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	slog.Info("settle done", "priceE6", priceE6, "txHash", txHash)
	writeJSON(w, http.StatusOK, settleResponse{
		StartTime: startTime,
		EndTime:   endTime,
		PriceE6:   priceE6,
		TxHash:    txHash,
	})
}

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// ---- CRE simulate ----

func (s *server) runSimulate(ctx context.Context, startTime, endTime int64) (uint64, error) {
	payload := fmt.Sprintf(`{"startTime":%d,"endTime":%d}`, startTime, endTime)

	cmd := exec.CommandContext(ctx, "cre", "workflow", "simulate", "vwap-eth-quote-flow",
		"--non-interactive",
		"--trigger-index", "0",
		"--http-payload", payload,
		"--target", "staging-settings",
	)
	cmd.Dir = s.cfg.creRepoDir

	slog.Info("running cre simulate", "dir", cmd.Dir, "payload", payload)

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
			"1": "InsufficientSources",
			"2": "StaleData",
			"3": "DeviationError",
			"4": "DataNotReady",
		}
		msg := statusMsg[string(statusMatch[1])]
		if msg == "" {
			msg = "Unknown"
		}
		return 0, fmt.Errorf("VWAP status %s (%s) — fail-closed, aborting", string(statusMatch[1]), msg)
	}

	priceE6, err := strconv.ParseUint(string(priceMatch[1]), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse priceE6: %w", err)
	}

	slog.Info("simulate result", "priceE6", priceE6)
	return priceE6, nil
}

// ---- on-chain send ----

func (s *server) sendReport(ctx context.Context, startTime, endTime int64, priceE6 uint64) (string, error) {
	client, err := ethclient.DialContext(ctx, s.cfg.rpcURL)
	if err != nil {
		return "", fmt.Errorf("dial rpc: %w", err)
	}
	defer client.Close()

	chainID, err := client.ChainID(ctx)
	if err != nil {
		return "", fmt.Errorf("get chain id: %w", err)
	}

	privKey, err := crypto.HexToECDSA(strings.TrimPrefix(s.cfg.deployerPrivKey, "0x"))
	if err != nil {
		return "", fmt.Errorf("parse private key: %w", err)
	}
	from := crypto.PubkeyToAddress(privKey.PublicKey)

	// Build rawReport: 109 zero bytes + abi.encode(startTime, endTime, priceE6)
	// Layout matches ManualVWAPOracle.onReport() expectations.
	uint256Ty, _ := abi.NewType("uint256", "", nil)
	encArgs := abi.Arguments{{Type: uint256Ty}, {Type: uint256Ty}, {Type: uint256Ty}}
	encoded, err := encArgs.Pack(
		big.NewInt(startTime),
		big.NewInt(endTime),
		new(big.Int).SetUint64(priceE6),
	)
	if err != nil {
		return "", fmt.Errorf("abi encode rawReport payload: %w", err)
	}
	rawReport := append(make([]byte, 109), encoded...)

	// Build calldata: MockKeystoneForwarder.report(oracleAddr, rawReport, 0x, [])
	parsedABI, err := abi.JSON(strings.NewReader(forwarderABIJSON))
	if err != nil {
		return "", fmt.Errorf("parse forwarder abi: %w", err)
	}
	calldata, err := parsedABI.Pack("report",
		s.cfg.oracleAddr,
		rawReport,
		[]byte{},
		[][]byte{},
	)
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
		baseFee = big.NewInt(1e9) // 1 gwei fallback (non-EIP-1559 chains)
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
