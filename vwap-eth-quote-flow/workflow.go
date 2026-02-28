package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"sort"
	"strconv"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
)

// --- Config ---

type EVMConfig struct {
	TokenAddress          string `json:"tokenAddress"`
	ReserveManagerAddress string `json:"reserveManagerAddress"`
	BalanceReaderAddress  string `json:"balanceReaderAddress"`
	ChainName             string `json:"chainName"`
	GasLimit              uint64 `json:"gasLimit"`
}

func (e *EVMConfig) GetChainSelector() (uint64, error) {
	return evm.ChainSelectorFromName(e.ChainName)
}

func (e *EVMConfig) NewEVMClient() (*evm.Client, error) {
	chainSelector, err := e.GetChainSelector()
	if err != nil {
		return nil, err
	}
	return &evm.Client{
		ChainSelector: chainSelector,
	}, nil
}

type Config struct {
	DeviationThresholdPct float64     `json:"deviationThresholdPct"`
	MinVenues             int         `json:"minVenues"`
	MaxStalenessMinutes   int         `json:"maxStalenessMinutes"`
	FlashCrashPct         float64     `json:"flashCrashPct"`
	MaxMissingCandles     int         `json:"maxMissingCandles"`
	AuthorizedKeys        []string    `json:"authorizedKeys"`
	EVMs                  []EVMConfig `json:"evms"`
}

// --- Domain Types ---

type Candle struct {
	OpenTime int64
	Open     float64
	High     float64
	Low      float64
	Close    float64
	BaseVol  float64
	QuoteVol float64
}

type ExchangeResult struct {
	Name            string
	VWAP            float64
	TotalBaseVol    float64
	TotalQuoteVol   float64
	LastCandleClose float64
	LastCandleTime  int64
	CandleCount     int
	Valid           bool
	InvalidReason   string
}

type VWAPResult struct {
	Price       float64 `consensus_aggregation:"median"`
	PriceE6     int64   `consensus_aggregation:"median"`
	SourceCount int64   `consensus_aggregation:"median"`
	Status      int64   `consensus_aggregation:"median"`
	AsOf        int64   `consensus_aggregation:"median"`
}

// Status constants
const (
	StatusOK                  int64 = 0
	StatusInsufficientSources int64 = 1
	StatusStaleData           int64 = 2
	StatusDeviationError      int64 = 3
	StatusDataNotReady        int64 = 4
)

const candleIntervalMs = int64(15 * 60 * 1000)

// Exchange names
const (
	exchangeBinance  = "Binance"
	exchangeOKX      = "OKX"
	exchangeBybit    = "Bybit"
	exchangeCoinbase = "Coinbase"
	exchangeBitget   = "Bitget"
)

// --- Settlement Request ---

type SettlementRequest struct {
	StartTime int64 `json:"startTime"`
	EndTime   int64 `json:"endTime"`
}

// --- Workflow ---

func InitWorkflow(config *Config, logger *slog.Logger, secretsProvider cre.SecretsProvider) (cre.Workflow[*Config], error) {
	// HTTP trigger — manual / backend-initiated settlement
	// Payload: {"startTime": unix, "endTime": unix}
	authorizedKeys := make([]*http.AuthorizedKey, len(config.AuthorizedKeys))
	for i, key := range config.AuthorizedKeys {
		authorizedKeys[i] = &http.AuthorizedKey{
			Type:      http.KeyType_KEY_TYPE_ECDSA_EVM,
			PublicKey: key,
		}
	}
	httpTrigger := http.Trigger(&http.Config{
		AuthorizedKeys: authorizedKeys,
	})

	// Cron trigger — fires every hour on the hour (UTC)
	// Computes: endTime = top of current hour, startTime = endTime - 12h
	cronTrigger := cron.Trigger(&cron.Config{Schedule: "0 0 * * * *"})

	return cre.Workflow[*Config]{
		cre.Handler(httpTrigger, onHTTPTrigger),
		cre.Handler(cronTrigger, onCronTrigger),
	}, nil
}

// onHTTPTrigger handles manually-initiated settlements.
// Expects payload: {"startTime": unix, "endTime": unix}
func onHTTPTrigger(config *Config, runtime cre.Runtime, payload *http.Payload) (string, error) {
	logger := runtime.Logger()

	var req SettlementRequest
	if err := json.Unmarshal(payload.Input, &req); err != nil {
		return "", fmt.Errorf("failed to parse settlement request: %w", err)
	}

	logger.Info("HTTP trigger received", "startTime", req.StartTime, "endTime", req.EndTime)

	return doVWAPSettlement(config, runtime, &req)
}

// onCronTrigger handles the hourly scheduled settlement.
// endTime = top of scheduled hour, startTime = endTime - 12h
func onCronTrigger(config *Config, runtime cre.Runtime, trigger *cron.Payload) (string, error) {
	logger := runtime.Logger()

	scheduledTime := trigger.ScheduledExecutionTime.AsTime()
	endTime := scheduledTime.Truncate(time.Hour).Unix()
	startTime := endTime - 12*3600

	logger.Info("cron trigger fired",
		"scheduledTime", scheduledTime,
		"startTime", startTime,
		"endTime", endTime,
	)

	return doVWAPSettlement(config, runtime, &SettlementRequest{
		StartTime: startTime,
		EndTime:   endTime,
	})
}

func doVWAPSettlement(config *Config, runtime cre.Runtime, req *SettlementRequest) (string, error) {
	logger := runtime.Logger()

	startTimeMs := req.StartTime * 1000
	endTimeMs := req.EndTime * 1000

	logger.Info("computing VWAP",
		"startTimeMs", startTimeMs,
		"endTimeMs", endTimeMs,
	)

	client := &http.Client{}
	computeFn := makeComputeVWAPForRange(startTimeMs, endTimeMs)
	vwapResult, err := http.SendRequest(config, runtime, client, computeFn, cre.ConsensusAggregationFromTags[*VWAPResult]()).Await()
	if err != nil {
		logger.Error("error computing VWAP", "err", err)
		return "", err
	}

	logger.Info("VWAP result",
		"price", vwapResult.Price,
		"priceE6", vwapResult.PriceE6,
		"sourceCount", vwapResult.SourceCount,
		"status", vwapResult.Status,
	)

	if vwapResult.Status != StatusOK {
		logger.Error("VWAP status not OK — fail closed, no on-chain write", "status", vwapResult.Status)
		return "", fmt.Errorf("VWAP status not OK: %d", vwapResult.Status)
	}

	if err := writeVWAPReport(config, runtime, req.StartTime, req.EndTime, vwapResult.PriceE6); err != nil {
		return "", fmt.Errorf("failed to write VWAP report: %w", err)
	}

	return fmt.Sprintf("%.6f", vwapResult.Price), nil
}

// --- VWAP Computation ---

type exchangeFetch struct {
	name   string
	url    string
	parser func([]byte) ([]Candle, error)
}

func makeComputeVWAPForRange(startTimeMs, endTimeMs int64) func(*Config, *slog.Logger, *http.SendRequester) (*VWAPResult, error) {
	return func(config *Config, logger *slog.Logger, sendRequester *http.SendRequester) (*VWAPResult, error) {
		return computeVWAPCore(config, logger, sendRequester, startTimeMs, endTimeMs)
	}
}

func buildExchangeURLs(startTimeMs, endTimeMs int64) []exchangeFetch {
	expectedCandles := int((endTimeMs - startTimeMs) / (15 * 60 * 1000))
	if expectedCandles < 1 {
		expectedCandles = 1
	}

	startTimeSec := startTimeMs / 1000
	endTimeSec := endTimeMs / 1000

	return []exchangeFetch{
		{
			exchangeBinance,
			fmt.Sprintf("https://api.binance.com/api/v3/klines?symbol=ETHUSDC&interval=15m&limit=%d&startTime=%d&endTime=%d",
				expectedCandles, startTimeMs, endTimeMs),
			parseBinance,
		},
		{
			exchangeOKX,
			fmt.Sprintf("https://www.okx.com/api/v5/market/candles?instId=ETH-USDC&bar=15m&limit=%d&before=%d&after=%d",
				expectedCandles, startTimeMs, endTimeMs),
			parseOKX,
		},
		{
			exchangeBybit,
			fmt.Sprintf("https://api.bybit.com/v5/market/kline?category=spot&symbol=ETHUSDC&interval=15&limit=%d&start=%d&end=%d",
				expectedCandles, startTimeMs, endTimeMs),
			parseBybit,
		},
		{
			exchangeCoinbase,
			fmt.Sprintf("https://api.exchange.coinbase.com/products/ETH-USD/candles?granularity=900&start=%d&end=%d",
				startTimeSec, endTimeSec),
			parseCoinbase,
		},
		{
			exchangeBitget,
			fmt.Sprintf("https://api.bitget.com/api/v2/spot/market/candles?symbol=ETHUSDC&granularity=15min&limit=%d&startTime=%d&endTime=%d",
				expectedCandles, startTimeMs, endTimeMs),
			parseBitget,
		},
	}
}

func computeVWAPCore(config *Config, logger *slog.Logger, sendRequester *http.SendRequester, startTimeMs, endTimeMs int64) (*VWAPResult, error) {
	endTimeSec := endTimeMs / 1000

	// Ceil startTime to next 15-min boundary so we only include candles
	// that started AFTER the order was placed (fairness: no pre-existing data advantage).
	queryStartMs := ((startTimeMs + candleIntervalMs - 1) / candleIntervalMs) * candleIntervalMs

	// The last candle that must be present: the one whose interval contains endTime
	requiredLastCandleMs := ((endTimeMs - 1) / candleIntervalMs) * candleIntervalMs

	expectedCandles := int((requiredLastCandleMs-queryStartMs)/candleIntervalMs) + 1
	if expectedCandles < 1 {
		expectedCandles = 1
	}

	exchanges := buildExchangeURLs(queryStartMs, endTimeMs)

	// Step 1: Fetch all exchanges and parse
	results := make([]ExchangeResult, 0, len(exchanges))
	for _, ex := range exchanges {
		resp, err := sendRequester.SendRequest(&http.Request{
			Method: "GET",
			Url:    ex.url,
		}).Await()
		if err != nil {
			logger.Warn("exchange fetch failed", "exchange", ex.name, "err", err)
			results = append(results, ExchangeResult{Name: ex.name, Valid: false, InvalidReason: fmt.Sprintf("fetch error: %v", err)})
			continue
		}

		candles, err := ex.parser(resp.Body)
		if err != nil {
			logger.Warn("exchange parse failed", "exchange", ex.name, "err", err)
			results = append(results, ExchangeResult{Name: ex.name, Valid: false, InvalidReason: fmt.Sprintf("parse error: %v", err)})
			continue
		}

		sort.Slice(candles, func(i, j int) bool {
			return candles[i].OpenTime < candles[j].OpenTime
		})

		if len(candles) == 0 {
			results = append(results, ExchangeResult{Name: ex.name, Valid: false, InvalidReason: "no candles returned"})
			continue
		}

		lastCandle := candles[len(candles)-1]
		if lastCandle.OpenTime < requiredLastCandleMs {
			reason := fmt.Sprintf("candle covering endTime not yet available: last=%d, required=%d", lastCandle.OpenTime, requiredLastCandleMs)
			logger.Warn("exchange filtered", "exchange", ex.name, "reason", reason)
			results = append(results, ExchangeResult{Name: ex.name, Valid: false, InvalidReason: reason})
			continue
		}

		missing := expectedCandles - len(candles)
		if missing > config.MaxMissingCandles {
			reason := fmt.Sprintf("too many missing candles: %d (max %d)", missing, config.MaxMissingCandles)
			logger.Warn("exchange filtered", "exchange", ex.name, "reason", reason)
			results = append(results, ExchangeResult{Name: ex.name, Valid: false, InvalidReason: reason})
			continue
		}

		var totalBaseVol, totalQuoteVol float64
		for _, c := range candles {
			if c.BaseVol <= 0 {
				continue
			}
			totalBaseVol += c.BaseVol
			totalQuoteVol += c.QuoteVol
		}

		if totalBaseVol <= 0 {
			results = append(results, ExchangeResult{Name: ex.name, Valid: false, InvalidReason: "zero total volume"})
			continue
		}

		vwap := totalQuoteVol / totalBaseVol

		results = append(results, ExchangeResult{
			Name:            ex.name,
			VWAP:            vwap,
			TotalBaseVol:    totalBaseVol,
			TotalQuoteVol:   totalQuoteVol,
			LastCandleClose: lastCandle.Close,
			LastCandleTime:  lastCandle.OpenTime,
			CandleCount:     len(candles),
			Valid:           true,
		})
	}

	// Step 2: Collect valid results
	valid := make([]ExchangeResult, 0)
	for _, r := range results {
		if r.Valid {
			valid = append(valid, r)
		}
	}

	if len(valid) < config.MinVenues {
		logger.Error("insufficient valid sources", "valid", len(valid), "min", config.MinVenues)
		return &VWAPResult{Status: StatusInsufficientSources, AsOf: endTimeSec}, nil
	}

	// Step 3: Compute median VWAP for outlier detection
	vwaps := make([]float64, len(valid))
	for i, r := range valid {
		vwaps[i] = r.VWAP
	}
	medianVWAP := medianFloat64(vwaps)

	// Step 4: Outlier scrubbing
	scrubbed := make([]ExchangeResult, 0)
	for _, r := range valid {
		deviation := math.Abs(r.VWAP-medianVWAP) / medianVWAP * 100.0
		if deviation > config.DeviationThresholdPct {
			logger.Warn("outlier scrubbed", "exchange", r.Name, "vwap", r.VWAP, "median", medianVWAP, "deviation", deviation)
			continue
		}
		scrubbed = append(scrubbed, r)
	}

	// Step 5: Check min venues after scrubbing
	if len(scrubbed) < config.MinVenues {
		logger.Error("insufficient sources after scrubbing", "remaining", len(scrubbed), "min", config.MinVenues)
		return &VWAPResult{Status: StatusInsufficientSources, AsOf: endTimeSec}, nil
	}

	// Step 6: Staleness check
	var latestCandleTime int64
	for _, r := range scrubbed {
		if r.LastCandleTime > latestCandleTime {
			latestCandleTime = r.LastCandleTime
		}
	}
	stalenessMinutes := float64(endTimeMs-latestCandleTime) / (60 * 1000)
	if stalenessMinutes > float64(config.MaxStalenessMinutes) {
		logger.Error("stale data", "latestCandleTime", latestCandleTime, "stalenessMinutes", stalenessMinutes)
		return &VWAPResult{Status: StatusStaleData, AsOf: endTimeSec}, nil
	}

	// Step 7: Final aggregation — volume-weighted average across exchanges
	var totalQuoteVol, totalBaseVol float64
	for _, r := range scrubbed {
		totalQuoteVol += r.TotalQuoteVol
		totalBaseVol += r.TotalBaseVol
	}
	finalVWAP := totalQuoteVol / totalBaseVol

	// Step 8: Flash crash check
	closes := make([]float64, len(scrubbed))
	for i, r := range scrubbed {
		closes[i] = r.LastCandleClose
	}
	medianClose := medianFloat64(closes)
	flashDeviation := math.Abs(finalVWAP-medianClose) / medianClose * 100.0
	if flashDeviation > config.FlashCrashPct {
		logger.Error("flash crash detected", "vwap", finalVWAP, "medianClose", medianClose, "deviation", flashDeviation)
		return &VWAPResult{Status: StatusDeviationError, AsOf: endTimeSec}, nil
	}

	priceE6 := int64(math.Round(finalVWAP * 1e6))

	return &VWAPResult{
		Price:       finalVWAP,
		PriceE6:     priceE6,
		SourceCount: int64(len(scrubbed)),
		Status:      StatusOK,
		AsOf:        endTimeSec,
	}, nil
}

// --- On-chain write ---

// writeVWAPReport submits (startTime, endTime, priceE6) to ChainlinkVWAPAdapter on-chain.
//
// Flow:
//  1. ABI-encode the three uint256 fields as the report payload.
//  2. Ask the CRE DON to sign the payload via runtime.GenerateReport — this produces a
//     consensus-signed cre.Report that the on-chain Forwarder can verify.
//  3. Call evm.Client.WriteReport, which routes through the CRE Forwarder and ultimately
//     invokes adapter.onReport(metadata, abi.encode(startTime, endTime, price)).
func writeVWAPReport(config *Config, runtime cre.Runtime, startTime, endTime, priceE6 int64) error {
	evmCfg := config.EVMs[0]
	logger := runtime.Logger()

	logger.Info("writing VWAP report on-chain",
		"startTime", startTime,
		"endTime", endTime,
		"priceE6", priceE6,
	)

	// ABI-encode (uint256, uint256, uint256) — each 32 bytes, big-endian, zero-padded.
	encoded := abiEncodeUint256x3(startTime, endTime, priceE6)

	// Request F+1 DON signatures on the encoded payload.
	report, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: encoded,
		EncoderName:    "evm",
		SigningAlgo:    "ecdsa",
		HashingAlgo:    "keccak256",
	}).Await()
	if err != nil {
		return fmt.Errorf("failed to generate report: %w", err)
	}

	evmClient, err := evmCfg.NewEVMClient()
	if err != nil {
		return fmt.Errorf("failed to create EVM client for %s: %w", evmCfg.ChainName, err)
	}

	receiverAddr := common.HexToAddress(evmCfg.ReserveManagerAddress).Bytes()
	resp, err := evmClient.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver: receiverAddr,
		Report:   report,
	}).Await()
	if err != nil {
		return fmt.Errorf("failed to write report: %w", err)
	}

	logger.Info("write report succeeded", "txHash", fmt.Sprintf("0x%x", resp.TxHash))
	return nil
}

// abiEncodeUint256x3 encodes three int64 values as ABI-packed uint256 × 3 (96 bytes total).
// Each value occupies 32 bytes, big-endian, zero-padded in the upper 24 bytes.
func abiEncodeUint256x3(a, b, c int64) []byte {
	buf := make([]byte, 96)
	binary.BigEndian.PutUint64(buf[24:32], uint64(a))
	binary.BigEndian.PutUint64(buf[56:64], uint64(b))
	binary.BigEndian.PutUint64(buf[88:96], uint64(c))
	return buf
}

// --- Exchange Parsers ---

// parseBinance parses Binance kline response (ascending order).
// Format: [[openTime, "open", "high", "low", "close", "baseVol", closeTime, "quoteVol", ...], ...]
func parseBinance(data []byte) ([]Candle, error) {
	var raw [][]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("binance: %w", err)
	}

	candles := make([]Candle, 0, len(raw))
	for _, row := range raw {
		if len(row) < 8 {
			continue
		}
		c := Candle{}
		if err := json.Unmarshal(row[0], &c.OpenTime); err != nil {
			return nil, fmt.Errorf("binance openTime: %w", err)
		}
		c.Open = parseJSONFloat(row[1])
		c.High = parseJSONFloat(row[2])
		c.Low = parseJSONFloat(row[3])
		c.Close = parseJSONFloat(row[4])
		c.BaseVol = parseJSONFloat(row[5])
		c.QuoteVol = parseJSONFloat(row[7]) // index 7 = quote asset volume
		candles = append(candles, c)
	}
	return candles, nil
}

// parseOKX parses OKX candle response (descending, needs reverse).
// Format: {"data": [["ts","open","high","low","close","baseVol","quoteVol"], ...]}
func parseOKX(data []byte) ([]Candle, error) {
	var resp struct {
		Data [][]string `json:"data"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, fmt.Errorf("okx: %w", err)
	}

	candles := make([]Candle, 0, len(resp.Data))
	for _, row := range resp.Data {
		if len(row) < 7 {
			continue
		}
		ts, _ := strconv.ParseInt(row[0], 10, 64)
		candles = append(candles, Candle{
			OpenTime: ts,
			Open:     parseFloat(row[1]),
			High:     parseFloat(row[2]),
			Low:      parseFloat(row[3]),
			Close:    parseFloat(row[4]),
			BaseVol:  parseFloat(row[5]),
			QuoteVol: parseFloat(row[6]),
		})
	}
	return candles, nil
}

// parseBybit parses Bybit kline response (descending, needs reverse).
// Format: {"result":{"list":[["ts","open","high","low","close","baseVol","turnover"], ...]}}
func parseBybit(data []byte) ([]Candle, error) {
	var resp struct {
		Result struct {
			List [][]string `json:"list"`
		} `json:"result"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, fmt.Errorf("bybit: %w", err)
	}

	candles := make([]Candle, 0, len(resp.Result.List))
	for _, row := range resp.Result.List {
		if len(row) < 7 {
			continue
		}
		ts, _ := strconv.ParseInt(row[0], 10, 64)
		candles = append(candles, Candle{
			OpenTime: ts,
			Open:     parseFloat(row[1]),
			High:     parseFloat(row[2]),
			Low:      parseFloat(row[3]),
			Close:    parseFloat(row[4]),
			BaseVol:  parseFloat(row[5]),
			QuoteVol: parseFloat(row[6]),
		})
	}
	return candles, nil
}

// parseCoinbase parses Coinbase candle response (descending, needs reverse).
// Format: [[time_seconds, low, high, open, close, volume], ...] — no quoteVol, uses typical price approximation.
func parseCoinbase(data []byte) ([]Candle, error) {
	var raw [][]json.Number
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("coinbase: %w", err)
	}

	candles := make([]Candle, 0, len(raw))
	for _, row := range raw {
		if len(row) < 6 {
			continue
		}
		ts, _ := row[0].Int64()
		low, _ := row[1].Float64()
		high, _ := row[2].Float64()
		open, _ := row[3].Float64()
		closePx, _ := row[4].Float64()
		baseVol, _ := row[5].Float64()

		typicalPrice := (high + low + closePx) / 3.0
		quoteVol := typicalPrice * baseVol

		candles = append(candles, Candle{
			OpenTime: ts * 1000,
			Open:     open,
			High:     high,
			Low:      low,
			Close:    closePx,
			BaseVol:  baseVol,
			QuoteVol: quoteVol,
		})
	}
	return candles, nil
}

// parseBitget parses Bitget candle response (descending, needs reverse).
// Format: {"data": [["ts","open","high","low","close","baseVol","quoteVol"], ...]}
func parseBitget(data []byte) ([]Candle, error) {
	var resp struct {
		Data [][]string `json:"data"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, fmt.Errorf("bitget: %w", err)
	}

	candles := make([]Candle, 0, len(resp.Data))
	for _, row := range resp.Data {
		if len(row) < 7 {
			continue
		}
		ts, _ := strconv.ParseInt(row[0], 10, 64)
		candles = append(candles, Candle{
			OpenTime: ts,
			Open:     parseFloat(row[1]),
			High:     parseFloat(row[2]),
			Low:      parseFloat(row[3]),
			Close:    parseFloat(row[4]),
			BaseVol:  parseFloat(row[5]),
			QuoteVol: parseFloat(row[6]),
		})
	}
	return candles, nil
}

// --- Helpers ---

func parseFloat(s string) float64 {
	f, _ := strconv.ParseFloat(s, 64)
	return f
}

func parseJSONFloat(raw json.RawMessage) float64 {
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		var f float64
		_ = json.Unmarshal(raw, &f)
		return f
	}
	return parseFloat(s)
}

func medianFloat64(vals []float64) float64 {
	sorted := make([]float64, len(vals))
	copy(sorted, vals)
	sort.Float64s(sorted)
	n := len(sorted)
	if n == 0 {
		return 0
	}
	if n%2 == 0 {
		return (sorted[n/2-1] + sorted[n/2]) / 2.0
	}
	return sorted[n/2]
}
