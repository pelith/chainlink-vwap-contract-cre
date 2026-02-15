package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm/bindings"
	evmmock "github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm/mock"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	httpmock "github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http/mock"
	"github.com/smartcontractkit/cre-sdk-go/cre/testutils"
	"github.com/stretchr/testify/require"

	"chainlink-vwap-cre/contracts/evm/src/generated/message_emitter"
)

// Fixed test time range (deterministic)
var (
	testStartTime   = int64(1700000000)                // unix seconds
	testEndTime     = testStartTime + 12*60*60         // +12 hours
	testStartTimeMs = testStartTime * 1000             // milliseconds
	testOrderID     = "42"
)

//go:embed config.production.json
var configJson []byte

func makeTestConfig(t *testing.T) *Config {
	config := &Config{}
	require.NoError(t, json.Unmarshal(configJson, config))
	return config
}

// --- Settlement request helper ---

func makeSettlementLog(orderId string, startTime, endTime int64) *bindings.DecodedLog[message_emitter.MessageEmittedDecoded] {
	msg, _ := json.Marshal(SettlementRequest{
		OrderID:   orderId,
		StartTime: startTime,
		EndTime:   endTime,
	})
	return &bindings.DecodedLog[message_emitter.MessageEmittedDecoded]{
		Log: &evm.Log{},
		Data: message_emitter.MessageEmittedDecoded{
			Emitter:   common.Address{},
			Timestamp: big.NewInt(testEndTime),
			Message:   string(msg),
		},
	}
}

// --- Mock data generators ---

// makeBinanceMock generates Binance klines JSON (ascending order) for testStartTimeMs~testEndTimeMs.
func makeBinanceMock(basePrice float64) []byte {
	rows := make([][]interface{}, 48)
	for i := 0; i < 48; i++ {
		ts := testStartTimeMs + int64(i)*15*60*1000
		price := basePrice + float64(i)*0.01
		vol := 100.0
		quoteVol := vol * price
		rows[i] = []interface{}{
			ts,
			fmt.Sprintf("%.2f", price),
			fmt.Sprintf("%.2f", price+1),
			fmt.Sprintf("%.2f", price-1),
			fmt.Sprintf("%.2f", price+0.5),
			fmt.Sprintf("%.4f", vol),
			ts + 15*60*1000 - 1,
			fmt.Sprintf("%.4f", quoteVol),
			100,
			fmt.Sprintf("%.4f", vol*0.5),
			fmt.Sprintf("%.4f", quoteVol*0.5),
			"0",
		}
	}
	data, _ := json.Marshal(rows)
	return data
}

// makeOKXMock generates OKX candles JSON (descending order).
func makeOKXMock(basePrice float64) []byte {
	rows := make([][]string, 48)
	for i := 0; i < 48; i++ {
		// descending: newest first
		idx := 47 - i
		ts := testStartTimeMs + int64(idx)*15*60*1000
		price := basePrice + float64(idx)*0.01
		vol := 100.0
		quoteVol := vol * price
		rows[i] = []string{
			fmt.Sprintf("%d", ts),
			fmt.Sprintf("%.2f", price),
			fmt.Sprintf("%.2f", price+1),
			fmt.Sprintf("%.2f", price-1),
			fmt.Sprintf("%.2f", price+0.5),
			fmt.Sprintf("%.4f", vol),
			fmt.Sprintf("%.4f", quoteVol),
		}
	}
	resp := struct {
		Data [][]string `json:"data"`
	}{Data: rows}
	data, _ := json.Marshal(resp)
	return data
}

// makeBybitMock generates Bybit kline JSON (descending order).
func makeBybitMock(basePrice float64) []byte {
	rows := make([][]string, 48)
	for i := 0; i < 48; i++ {
		idx := 47 - i
		ts := testStartTimeMs + int64(idx)*15*60*1000
		price := basePrice + float64(idx)*0.01
		vol := 100.0
		quoteVol := vol * price
		rows[i] = []string{
			fmt.Sprintf("%d", ts),
			fmt.Sprintf("%.2f", price),
			fmt.Sprintf("%.2f", price+1),
			fmt.Sprintf("%.2f", price-1),
			fmt.Sprintf("%.2f", price+0.5),
			fmt.Sprintf("%.4f", vol),
			fmt.Sprintf("%.4f", quoteVol),
		}
	}
	resp := struct {
		Result struct {
			List [][]string `json:"list"`
		} `json:"result"`
	}{}
	resp.Result.List = rows
	data, _ := json.Marshal(resp)
	return data
}

// makeCoinbaseMock generates Coinbase candles JSON (descending order, LHOCV, seconds).
func makeCoinbaseMock(basePrice float64) []byte {
	rows := make([][]interface{}, 48)
	for i := 0; i < 48; i++ {
		idx := 47 - i
		ts := testStartTime + int64(idx)*15*60 // seconds
		price := basePrice + float64(idx)*0.01
		vol := 100.0
		rows[i] = []interface{}{
			ts,
			price - 1,   // low
			price + 1,   // high
			price,       // open
			price + 0.5, // close
			vol,
		}
	}
	data, _ := json.Marshal(rows)
	return data
}

// makeBitgetMock generates Bitget candles JSON (descending order).
func makeBitgetMock(basePrice float64) []byte {
	rows := make([][]string, 48)
	for i := 0; i < 48; i++ {
		idx := 47 - i
		ts := testStartTimeMs + int64(idx)*15*60*1000
		price := basePrice + float64(idx)*0.01
		vol := 100.0
		quoteVol := vol * price
		rows[i] = []string{
			fmt.Sprintf("%d", ts),
			fmt.Sprintf("%.2f", price),
			fmt.Sprintf("%.2f", price+1),
			fmt.Sprintf("%.2f", price-1),
			fmt.Sprintf("%.2f", price+0.5),
			fmt.Sprintf("%.4f", vol),
			fmt.Sprintf("%.4f", quoteVol),
		}
	}
	resp := struct {
		Data [][]string `json:"data"`
	}{Data: rows}
	data, _ := json.Marshal(resp)
	return data
}

// --- URL routing helper ---

func routeExchangeMock(url string, mocks map[string][]byte) (*http.Response, error) {
	for substr, body := range mocks {
		if strings.Contains(url, substr) {
			return &http.Response{Body: body}, nil
		}
	}
	return nil, fmt.Errorf("unrecognized URL: %s", url)
}

// --- Setup helpers ---

func setupEVMMock(t *testing.T, config *Config) {
	chainSelector, err := config.EVMs[0].GetChainSelector()
	require.NoError(t, err)
	evmMock, err := evmmock.NewClientCapability(chainSelector, t)
	require.NoError(t, err)
	evmMock.WriteReport = func(ctx context.Context, input *evm.WriteReportRequest) (*evm.WriteReportReply, error) {
		return &evm.WriteReportReply{
			TxHash: common.HexToHash("0xaabbccdd").Bytes(),
		}, nil
	}
}

// --- Tests ---

func TestInitWorkflow(t *testing.T) {
	config := makeTestConfig(t)
	runtime := testutils.NewRuntime(t, testutils.Secrets{})

	workflow, err := InitWorkflow(config, runtime.Logger(), nil)
	require.NoError(t, err)

	require.Len(t, workflow, 1) // log trigger handler
}

func TestHappyPath(t *testing.T) {
	config := makeTestConfig(t)
	runtime := testutils.NewRuntime(t, testutils.Secrets{
		"": {},
	})

	// Mock HTTP — all 5 exchanges return normal data around $2000
	httpMock, err := httpmock.NewClientCapability(t)
	require.NoError(t, err)
	mocks := map[string][]byte{
		"binance.com":  makeBinanceMock(2000.0),
		"okx.com":      makeOKXMock(2000.0),
		"bybit.com":    makeBybitMock(2000.0),
		"coinbase.com": makeCoinbaseMock(2000.0),
		"bitget.com":   makeBitgetMock(2000.0),
	}
	httpMock.SendRequest = func(ctx context.Context, input *http.Request) (*http.Response, error) {
		return routeExchangeMock(input.Url, mocks)
	}

	// Mock EVM
	setupEVMMock(t, config)

	result, err := onSettlementRequest(config, runtime, makeSettlementLog(testOrderID, testStartTime, testEndTime))

	require.NoError(t, err)
	require.NotEmpty(t, result)

	// Verify logs
	logs := runtime.GetLogs()
	assertLogContains(t, logs, `msg="settlement request received"`)
	assertLogContains(t, logs, `msg="computing VWAP for settlement"`)
	assertLogContains(t, logs, `msg="VWAP result"`)
	assertLogContains(t, logs, `msg="Write report transaction succeeded at"`)
}

func TestOutlierScrubbing(t *testing.T) {
	config := makeTestConfig(t)
	runtime := testutils.NewRuntime(t, testutils.Secrets{
		"": {},
	})

	// Mock HTTP — 4 exchanges at $2000, 1 outlier at $2100 (>2% deviation)
	httpMock, err := httpmock.NewClientCapability(t)
	require.NoError(t, err)
	mocks := map[string][]byte{
		"binance.com":  makeBinanceMock(2000.0),
		"okx.com":      makeOKXMock(2000.0),
		"bybit.com":    makeBybitMock(2000.0),
		"coinbase.com": makeCoinbaseMock(2000.0),
		"bitget.com":   makeBitgetMock(2100.0), // >2% away from median
	}
	httpMock.SendRequest = func(ctx context.Context, input *http.Request) (*http.Response, error) {
		return routeExchangeMock(input.Url, mocks)
	}

	setupEVMMock(t, config)

	result, err := onSettlementRequest(config, runtime, makeSettlementLog(testOrderID, testStartTime, testEndTime))

	require.NoError(t, err)
	require.NotEmpty(t, result)

	// Verify outlier was scrubbed
	logs := runtime.GetLogs()
	assertLogContains(t, logs, `msg="outlier scrubbed"`)
	// Should still succeed with 4 remaining exchanges
	assertLogContains(t, logs, `msg="Write report transaction succeeded at"`)
}

func TestInsufficientSources(t *testing.T) {
	config := makeTestConfig(t)
	runtime := testutils.NewRuntime(t, testutils.Secrets{
		"": {},
	})

	// Mock HTTP — only 2 exchanges return valid data, 3 fail
	httpMock, err := httpmock.NewClientCapability(t)
	require.NoError(t, err)
	mocks := map[string][]byte{
		"binance.com": makeBinanceMock(2000.0),
		"okx.com":     makeOKXMock(2000.0),
	}
	httpMock.SendRequest = func(ctx context.Context, input *http.Request) (*http.Response, error) {
		resp, err := routeExchangeMock(input.Url, mocks)
		if err != nil {
			return nil, fmt.Errorf("exchange unavailable")
		}
		return resp, nil
	}

	setupEVMMock(t, config)

	_, err = onSettlementRequest(config, runtime, makeSettlementLog(testOrderID, testStartTime, testEndTime))

	// Should fail because only 2 < minVenues(3)
	require.Error(t, err)

	logs := runtime.GetLogs()
	assertLogContains(t, logs, `msg="insufficient valid sources"`)
}

func TestStaleData(t *testing.T) {
	config := makeTestConfig(t)
	runtime := testutils.NewRuntime(t, testutils.Secrets{
		"": {},
	})

	// Generate candle data with timestamps ending 2 hours before endTime (stale)
	staleBaseMs := testStartTimeMs - 2*60*60*1000 // shift all candles 2h earlier

	makeStaleCandles := func(basePrice float64) []byte {
		rows := make([][]interface{}, 48)
		for i := 0; i < 48; i++ {
			ts := staleBaseMs + int64(i)*15*60*1000
			price := basePrice + float64(i)*0.01
			vol := 100.0
			quoteVol := vol * price
			rows[i] = []interface{}{
				ts,
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.2f", price+1),
				fmt.Sprintf("%.2f", price-1),
				fmt.Sprintf("%.2f", price+0.5),
				fmt.Sprintf("%.4f", vol),
				ts + 15*60*1000 - 1,
				fmt.Sprintf("%.4f", quoteVol),
				100,
				fmt.Sprintf("%.4f", vol*0.5),
				fmt.Sprintf("%.4f", quoteVol*0.5),
				"0",
			}
		}
		data, _ := json.Marshal(rows)
		return data
	}

	makeStaleOKX := func(basePrice float64) []byte {
		rows := make([][]string, 48)
		for i := 0; i < 48; i++ {
			idx := 47 - i
			ts := staleBaseMs + int64(idx)*15*60*1000
			price := basePrice + float64(idx)*0.01
			vol := 100.0
			quoteVol := vol * price
			rows[i] = []string{
				fmt.Sprintf("%d", ts),
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.2f", price+1),
				fmt.Sprintf("%.2f", price-1),
				fmt.Sprintf("%.2f", price+0.5),
				fmt.Sprintf("%.4f", vol),
				fmt.Sprintf("%.4f", quoteVol),
			}
		}
		resp := struct {
			Data [][]string `json:"data"`
		}{Data: rows}
		data, _ := json.Marshal(resp)
		return data
	}

	makeStaleBybit := func(basePrice float64) []byte {
		rows := make([][]string, 48)
		for i := 0; i < 48; i++ {
			idx := 47 - i
			ts := staleBaseMs + int64(idx)*15*60*1000
			price := basePrice + float64(idx)*0.01
			vol := 100.0
			quoteVol := vol * price
			rows[i] = []string{
				fmt.Sprintf("%d", ts),
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.2f", price+1),
				fmt.Sprintf("%.2f", price-1),
				fmt.Sprintf("%.2f", price+0.5),
				fmt.Sprintf("%.4f", vol),
				fmt.Sprintf("%.4f", quoteVol),
			}
		}
		resp := struct {
			Result struct {
				List [][]string `json:"list"`
			} `json:"result"`
		}{}
		resp.Result.List = rows
		data, _ := json.Marshal(resp)
		return data
	}

	makeStaleCoinbase := func(basePrice float64) []byte {
		staleBaseSec := staleBaseMs / 1000
		rows := make([][]interface{}, 48)
		for i := 0; i < 48; i++ {
			idx := 47 - i
			ts := staleBaseSec + int64(idx)*15*60
			price := basePrice + float64(idx)*0.01
			vol := 100.0
			rows[i] = []interface{}{ts, price - 1, price + 1, price, price + 0.5, vol}
		}
		data, _ := json.Marshal(rows)
		return data
	}

	makeStaleBitget := func(basePrice float64) []byte {
		rows := make([][]string, 48)
		for i := 0; i < 48; i++ {
			idx := 47 - i
			ts := staleBaseMs + int64(idx)*15*60*1000
			price := basePrice + float64(idx)*0.01
			vol := 100.0
			quoteVol := vol * price
			rows[i] = []string{
				fmt.Sprintf("%d", ts),
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.2f", price+1),
				fmt.Sprintf("%.2f", price-1),
				fmt.Sprintf("%.2f", price+0.5),
				fmt.Sprintf("%.4f", vol),
				fmt.Sprintf("%.4f", quoteVol),
			}
		}
		resp := struct {
			Data [][]string `json:"data"`
		}{Data: rows}
		data, _ := json.Marshal(resp)
		return data
	}

	httpMock, err := httpmock.NewClientCapability(t)
	require.NoError(t, err)
	mocks := map[string][]byte{
		"binance.com":  makeStaleCandles(2000.0),
		"okx.com":      makeStaleOKX(2000.0),
		"bybit.com":    makeStaleBybit(2000.0),
		"coinbase.com": makeStaleCoinbase(2000.0),
		"bitget.com":   makeStaleBitget(2000.0),
	}
	httpMock.SendRequest = func(ctx context.Context, input *http.Request) (*http.Response, error) {
		return routeExchangeMock(input.Url, mocks)
	}

	setupEVMMock(t, config)

	_, err = onSettlementRequest(config, runtime, makeSettlementLog(testOrderID, testStartTime, testEndTime))

	require.Error(t, err)

	logs := runtime.GetLogs()
	assertLogContains(t, logs, `msg="stale data"`)
}

func TestFlashCrash(t *testing.T) {
	config := makeTestConfig(t)
	runtime := testutils.NewRuntime(t, testutils.Secrets{
		"": {},
	})

	// Create candles where earlier candles have high prices (~$2300) driving VWAP up,
	// but the last few candles have crashed to ~$1900 (>15% deviation of VWAP vs close).
	makeFlashBinance := func() []byte {
		rows := make([][]interface{}, 48)
		for i := 0; i < 48; i++ {
			ts := testStartTimeMs + int64(i)*15*60*1000
			var price float64
			var vol float64
			if i < 44 {
				price = 2300.0
				vol = 200.0
			} else {
				price = 1900.0
				vol = 50.0
			}
			quoteVol := vol * price
			rows[i] = []interface{}{
				ts,
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.2f", price+1),
				fmt.Sprintf("%.2f", price-1),
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.4f", vol),
				ts + 15*60*1000 - 1,
				fmt.Sprintf("%.4f", quoteVol),
				100,
				fmt.Sprintf("%.4f", vol*0.5),
				fmt.Sprintf("%.4f", quoteVol*0.5),
				"0",
			}
		}
		data, _ := json.Marshal(rows)
		return data
	}

	makeFlashOKX := func() []byte {
		rows := make([][]string, 48)
		for i := 0; i < 48; i++ {
			idx := 47 - i
			ts := testStartTimeMs + int64(idx)*15*60*1000
			var price, vol float64
			if idx < 44 {
				price = 2300.0
				vol = 200.0
			} else {
				price = 1900.0
				vol = 50.0
			}
			quoteVol := vol * price
			rows[i] = []string{
				fmt.Sprintf("%d", ts),
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.2f", price+1),
				fmt.Sprintf("%.2f", price-1),
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.4f", vol),
				fmt.Sprintf("%.4f", quoteVol),
			}
		}
		resp := struct {
			Data [][]string `json:"data"`
		}{Data: rows}
		data, _ := json.Marshal(resp)
		return data
	}

	makeFlashBybit := func() []byte {
		rows := make([][]string, 48)
		for i := 0; i < 48; i++ {
			idx := 47 - i
			ts := testStartTimeMs + int64(idx)*15*60*1000
			var price, vol float64
			if idx < 44 {
				price = 2300.0
				vol = 200.0
			} else {
				price = 1900.0
				vol = 50.0
			}
			quoteVol := vol * price
			rows[i] = []string{
				fmt.Sprintf("%d", ts),
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.2f", price+1),
				fmt.Sprintf("%.2f", price-1),
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.4f", vol),
				fmt.Sprintf("%.4f", quoteVol),
			}
		}
		resp := struct {
			Result struct {
				List [][]string `json:"list"`
			} `json:"result"`
		}{}
		resp.Result.List = rows
		data, _ := json.Marshal(resp)
		return data
	}

	makeFlashCoinbase := func() []byte {
		rows := make([][]interface{}, 48)
		for i := 0; i < 48; i++ {
			idx := 47 - i
			ts := testStartTime + int64(idx)*15*60 // seconds
			var price, vol float64
			if idx < 44 {
				price = 2300.0
				vol = 200.0
			} else {
				price = 1900.0
				vol = 50.0
			}
			rows[i] = []interface{}{ts, price - 1, price + 1, price, price, vol}
		}
		data, _ := json.Marshal(rows)
		return data
	}

	makeFlashBitget := func() []byte {
		rows := make([][]string, 48)
		for i := 0; i < 48; i++ {
			idx := 47 - i
			ts := testStartTimeMs + int64(idx)*15*60*1000
			var price, vol float64
			if idx < 44 {
				price = 2300.0
				vol = 200.0
			} else {
				price = 1900.0
				vol = 50.0
			}
			quoteVol := vol * price
			rows[i] = []string{
				fmt.Sprintf("%d", ts),
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.2f", price+1),
				fmt.Sprintf("%.2f", price-1),
				fmt.Sprintf("%.2f", price),
				fmt.Sprintf("%.4f", vol),
				fmt.Sprintf("%.4f", quoteVol),
			}
		}
		resp := struct {
			Data [][]string `json:"data"`
		}{Data: rows}
		data, _ := json.Marshal(resp)
		return data
	}

	httpMock, err := httpmock.NewClientCapability(t)
	require.NoError(t, err)
	mocks := map[string][]byte{
		"binance.com":  makeFlashBinance(),
		"okx.com":      makeFlashOKX(),
		"bybit.com":    makeFlashBybit(),
		"coinbase.com": makeFlashCoinbase(),
		"bitget.com":   makeFlashBitget(),
	}
	httpMock.SendRequest = func(ctx context.Context, input *http.Request) (*http.Response, error) {
		return routeExchangeMock(input.Url, mocks)
	}

	setupEVMMock(t, config)

	_, err = onSettlementRequest(config, runtime, makeSettlementLog(testOrderID, testStartTime, testEndTime))

	require.Error(t, err)

	logs := runtime.GetLogs()
	assertLogContains(t, logs, `msg="flash crash detected"`)
}

func TestPackSettlement(t *testing.T) {
	orderId, packed := packSettlement("42", 1700000000, 1700043200, 200000000000)
	require.NotNil(t, orderId)
	require.NotNil(t, packed)
	require.Equal(t, int64(42), orderId.Int64())

	// Verify unpacking
	// startTime = packed >> 128
	startTime := new(big.Int).Rsh(packed, 128)
	require.Equal(t, int64(1700000000), startTime.Int64())

	// endTime = (packed >> 64) & ((1<<64)-1)
	mask64 := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 64), big.NewInt(1))
	endTime := new(big.Int).And(new(big.Int).Rsh(packed, 64), mask64)
	require.Equal(t, int64(1700043200), endTime.Int64())

	// priceE8 = packed & ((1<<64)-1)
	priceE8 := new(big.Int).And(packed, mask64)
	require.Equal(t, int64(200000000000), priceE8.Int64())
}

// --- Helpers ---

func assertLogContains(t *testing.T, logs [][]byte, substr string) {
	t.Helper()
	for _, line := range logs {
		if strings.Contains(string(line), substr) {
			return
		}
	}
	t.Fatalf("Expected logs to contain substring %q, but it was not found in logs:\n%s",
		substr, strings.Join(func() []string {
			var logStrings []string
			for _, log := range logs {
				logStrings = append(logStrings, string(log))
			}
			return logStrings
		}(), "\n"))
}
