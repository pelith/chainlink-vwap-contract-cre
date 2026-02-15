package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"math/big"
	"sort"
	"strconv"

	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm/bindings"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/cre"

	"chainlink-vwap-cre/contracts/evm/src/generated/message_emitter"
	"chainlink-vwap-cre/contracts/evm/src/generated/reserve_manager"
)

// --- Config ---

type EVMConfig struct {
	TokenAddress          string `json:"tokenAddress"`
	ReserveManagerAddress string `json:"reserveManagerAddress"`
	BalanceReaderAddress  string `json:"balanceReaderAddress"`
	MessageEmitterAddress string `json:"messageEmitterAddress"`
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
	PriceE8     int64   `consensus_aggregation:"median"`
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
)

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
	OrderID   string `json:"orderId"`
	StartTime int64  `json:"startTime"`
	EndTime   int64  `json:"endTime"`
}

// --- Workflow ---

func InitWorkflow(config *Config, logger *slog.Logger, secretsProvider cre.SecretsProvider) (cre.Workflow[*Config], error) {
	evmCfg := config.EVMs[0]

	evmClient, err := evmCfg.NewEVMClient()
	if err != nil {
		return nil, fmt.Errorf("failed to create EVM client: %w", err)
	}

	chainSelector, err := evmCfg.GetChainSelector()
	if err != nil {
		return nil, fmt.Errorf("failed to get chain selector: %w", err)
	}

	msgEmitter, err := message_emitter.NewMessageEmitter(
		evmClient,
		common.HexToAddress(evmCfg.MessageEmitterAddress),
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create message emitter: %w", err)
	}

	logTrigger, err := msgEmitter.LogTriggerMessageEmittedLog(
		chainSelector,
		evm.ConfidenceLevel_CONFIDENCE_LEVEL_FINALIZED,
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create log trigger: %w", err)
	}

	workflow := cre.Workflow[*Config]{
		cre.Handler(logTrigger, onSettlementRequest),
	}

	return workflow, nil
}

func onSettlementRequest(config *Config, runtime cre.Runtime, outputs *bindings.DecodedLog[message_emitter.MessageEmittedDecoded]) (string, error) {
	logger := runtime.Logger()

	var req SettlementRequest
	if err := json.Unmarshal([]byte(outputs.Data.Message), &req); err != nil {
		return "", fmt.Errorf("failed to parse settlement request: %w", err)
	}

	logger.Info("settlement request received",
		"orderId", req.OrderID,
		"startTime", req.StartTime,
		"endTime", req.EndTime,
	)

	return doVWAPSettlement(config, runtime, &req)
}

func doVWAPSettlement(config *Config, runtime cre.Runtime, req *SettlementRequest) (string, error) {
	logger := runtime.Logger()

	startTimeMs := req.StartTime * 1000
	endTimeMs := req.EndTime * 1000

	logger.Info("computing VWAP for settlement",
		"orderId", req.OrderID,
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
		"priceE8", vwapResult.PriceE8,
		"sourceCount", vwapResult.SourceCount,
		"status", vwapResult.Status,
	)

	if vwapResult.Status != StatusOK {
		logger.Error("VWAP status not OK", "status", vwapResult.Status)
		return "", fmt.Errorf("VWAP status not OK: %d", vwapResult.Status)
	}

	orderId, packed := packSettlement(req.OrderID, req.StartTime, req.EndTime, vwapResult.PriceE8)
	if orderId == nil {
		return "", fmt.Errorf("invalid orderId: %s", req.OrderID)
	}

	if err := updateReserves(config, runtime, orderId, packed); err != nil {
		return "", fmt.Errorf("failed to write settlement: %w", err)
	}

	return fmt.Sprintf("%.8f", vwapResult.Price), nil
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
			fmt.Sprintf("https://api.exchange.coinbase.com/products/ETH-USDC/candles?granularity=900&start=%d&end=%d",
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
	expectedCandles := int((endTimeMs - startTimeMs) / (15 * 60 * 1000))
	if expectedCandles < 1 {
		expectedCandles = 1
	}

	exchanges := buildExchangeURLs(startTimeMs, endTimeMs)

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

		// Step 2: Initial filtering — missing candles
		missing := expectedCandles - len(candles)
		if missing > config.MaxMissingCandles {
			reason := fmt.Sprintf("too many missing candles: %d (max %d)", missing, config.MaxMissingCandles)
			logger.Warn("exchange filtered", "exchange", ex.name, "reason", reason)
			results = append(results, ExchangeResult{Name: ex.name, Valid: false, InvalidReason: reason})
			continue
		}

		// Compute per-exchange VWAP = Σ(quoteVol) / Σ(baseVol)
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
		lastCandle := candles[len(candles)-1]

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

	// Step 3: Collect valid results
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

	// Step 4: Compute median VWAP for outlier detection
	vwaps := make([]float64, len(valid))
	for i, r := range valid {
		vwaps[i] = r.VWAP
	}
	medianVWAP := medianFloat64(vwaps)

	// Step 5: Outlier scrubbing — remove exchanges deviating >deviationThresholdPct from median
	scrubbed := make([]ExchangeResult, 0)
	for _, r := range valid {
		deviation := math.Abs(r.VWAP-medianVWAP) / medianVWAP * 100.0
		if deviation > config.DeviationThresholdPct {
			logger.Warn("outlier scrubbed", "exchange", r.Name, "vwap", r.VWAP, "median", medianVWAP, "deviation", deviation)
			continue
		}
		scrubbed = append(scrubbed, r)
	}

	// Step 6: Check min venues after scrubbing
	if len(scrubbed) < config.MinVenues {
		logger.Error("insufficient sources after scrubbing", "remaining", len(scrubbed), "min", config.MinVenues)
		return &VWAPResult{Status: StatusInsufficientSources, AsOf: endTimeSec}, nil
	}

	// Step 7: Staleness check — latest candle must be within maxStalenessMinutes of endTime
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

	// Step 8: Final aggregation — volume-weighted average of remaining exchanges
	var totalQuoteVol, totalBaseVol float64
	for _, r := range scrubbed {
		totalQuoteVol += r.TotalQuoteVol
		totalBaseVol += r.TotalBaseVol
	}
	finalVWAP := totalQuoteVol / totalBaseVol

	// Step 9: Flash crash check — VWAP vs median of last candle closes
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

	priceE8 := int64(math.Round(finalVWAP * 1e8))

	return &VWAPResult{
		Price:       finalVWAP,
		PriceE8:     priceE8,
		SourceCount: int64(len(scrubbed)),
		Status:      StatusOK,
		AsOf:        endTimeSec,
	}, nil
}

// --- Settlement Packing ---

func packSettlement(orderIDStr string, startTimeSec, endTimeSec, priceE8 int64) (*big.Int, *big.Int) {
	orderId := new(big.Int)
	_, ok := orderId.SetString(orderIDStr, 10)
	if !ok {
		return nil, nil
	}

	packed := new(big.Int)
	packed.Lsh(big.NewInt(startTimeSec), 128)

	endShifted := new(big.Int).Lsh(big.NewInt(endTimeSec), 64)
	packed.Or(packed, endShifted)

	packed.Or(packed, big.NewInt(priceE8))

	return orderId, packed
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
	reverseCandles(candles)
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
	reverseCandles(candles)
	return candles, nil
}

// parseCoinbase parses Coinbase candle response (descending, needs reverse).
// Format: [[time_seconds, low, high, open, close, volume], ...] — LHOCV order, no quoteVol.
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

		// Coinbase does not provide quoteVol; approximate with typical price
		typicalPrice := (high + low + closePx) / 3.0
		quoteVol := typicalPrice * baseVol

		candles = append(candles, Candle{
			OpenTime: ts * 1000, // seconds → milliseconds
			Open:     open,
			High:     high,
			Low:      low,
			Close:    closePx,
			BaseVol:  baseVol,
			QuoteVol: quoteVol,
		})
	}
	reverseCandles(candles)
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
	reverseCandles(candles)
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

func reverseCandles(candles []Candle) {
	for i, j := 0, len(candles)-1; i < j; i, j = i+1, j-1 {
		candles[i], candles[j] = candles[j], candles[i]
	}
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

// --- On-chain write ---

func updateReserves(config *Config, runtime cre.Runtime, totalMinted *big.Int, totalReserve *big.Int) error {
	evmCfg := config.EVMs[0]
	logger := runtime.Logger()
	logger.Info("Writing settlement", "totalMinted", totalMinted, "totalReserve", totalReserve)

	evmClient, err := evmCfg.NewEVMClient()
	if err != nil {
		return fmt.Errorf("failed to create EVM client for %s: %w", evmCfg.ChainName, err)
	}

	reserveManager, err := reserve_manager.NewReserveManager(evmClient, common.HexToAddress(evmCfg.ReserveManagerAddress), nil)
	if err != nil {
		return fmt.Errorf("failed to create reserve manager: %w", err)
	}

	resp, err := reserveManager.WriteReportFromUpdateReserves(runtime, reserve_manager.UpdateReserves{
		TotalMinted:  totalMinted,
		TotalReserve: totalReserve,
	}, nil).Await()

	if err != nil {
		logger.Error("WriteReport await failed", "error", err, "errorType", fmt.Sprintf("%T", err))
		return fmt.Errorf("failed to write report: %w", err)
	}
	logger.Info("Write report succeeded", "response", resp)
	logger.Info("Write report transaction succeeded at", "txHash", common.BytesToHash(resp.TxHash).Hex())
	return nil
}
