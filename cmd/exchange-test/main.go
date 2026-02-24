package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"
	"time"
)

// --- Types (duplicated from workflow for standalone use) ---

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
	RawSize         int
}

type exchangeFetch struct {
	name   string
	url    string
	parser func([]byte) ([]Candle, error)
}

// --- Main ---

func main() {
	// Default: last 12 hours
	endTime := time.Now()
	startTime := endTime.Add(-12 * time.Hour)

	// Allow override via args: ./exchange-test [startUnix] [endUnix]
	if len(os.Args) >= 3 {
		s, err1 := strconv.ParseInt(os.Args[1], 10, 64)
		e, err2 := strconv.ParseInt(os.Args[2], 10, 64)
		if err1 == nil && err2 == nil {
			startTime = time.Unix(s, 0)
			endTime = time.Unix(e, 0)
		}
	}

	startMs := startTime.UnixMilli()
	endMs := endTime.UnixMilli()
	startSec := startTime.Unix()
	endSec := endTime.Unix()
	expectedCandles := int((endMs - startMs) / (15 * 60 * 1000))

	fmt.Println("=== Exchange API Test ===")
	fmt.Printf("Time range: %s → %s\n", startTime.UTC().Format(time.RFC3339), endTime.UTC().Format(time.RFC3339))
	fmt.Printf("Start: %d  End: %d  (unix seconds)\n", startSec, endSec)
	fmt.Printf("Expected ~%d candles (15min interval)\n\n", expectedCandles)

	exchanges := []exchangeFetch{
		{
			"Binance",
			fmt.Sprintf("https://api.binance.com/api/v3/klines?symbol=ETHUSDC&interval=15m&limit=%d&startTime=%d&endTime=%d",
				expectedCandles, startMs, endMs),
			parseBinance,
		},
		{
			"OKX",
			fmt.Sprintf("https://www.okx.com/api/v5/market/candles?instId=ETH-USDC&bar=15m&limit=%d&before=%d&after=%d",
				expectedCandles, startMs, endMs),
			parseOKX,
		},
		{
			"Bybit",
			fmt.Sprintf("https://api.bybit.com/v5/market/kline?category=spot&symbol=ETHUSDC&interval=15&limit=%d&start=%d&end=%d",
				expectedCandles, startMs, endMs),
			parseBybit,
		},
		{
			"Coinbase",
			fmt.Sprintf("https://api.exchange.coinbase.com/products/ETH-USD/candles?granularity=900&start=%d&end=%d",
				startSec, endSec),
			parseCoinbase,
		},
		{
			"Bitget",
			fmt.Sprintf("https://api.bitget.com/api/v2/spot/market/candles?symbol=ETHUSDC&granularity=15min&limit=%d&startTime=%d&endTime=%d",
				expectedCandles, startMs, endMs),
			parseBitget,
		},
	}

	results := make([]ExchangeResult, 0, len(exchanges))

	for _, ex := range exchanges {
		fmt.Printf("--- %s ---\n", ex.name)
		fmt.Printf("URL: %s\n", ex.url)

		body, err := fetchURL(ex.url)
		if err != nil {
			fmt.Printf("  ERROR fetching: %v\n\n", err)
			results = append(results, ExchangeResult{Name: ex.name, Valid: false, InvalidReason: err.Error()})
			continue
		}
		fmt.Printf("  Response size: %d bytes\n", len(body))

		// Print first 500 chars of raw response for debugging
		preview := string(body)
		if len(preview) > 500 {
			preview = preview[:500] + "..."
		}
		fmt.Printf("  Raw preview: %s\n", preview)

		candles, err := ex.parser(body)
		if err != nil {
			fmt.Printf("  ERROR parsing: %v\n\n", err)
			results = append(results, ExchangeResult{Name: ex.name, Valid: false, InvalidReason: err.Error(), RawSize: len(body)})
			continue
		}

		fmt.Printf("  Parsed candles: %d\n", len(candles))

		if len(candles) == 0 {
			fmt.Printf("  WARNING: no candles returned\n\n")
			results = append(results, ExchangeResult{Name: ex.name, Valid: false, InvalidReason: "no candles", RawSize: len(body)})
			continue
		}

		// Print first and last candle
		first := candles[0]
		last := candles[len(candles)-1]
		fmt.Printf("  First candle: time=%s  O=%.2f H=%.2f L=%.2f C=%.2f baseVol=%.4f quoteVol=%.4f\n",
			time.UnixMilli(first.OpenTime).UTC().Format(time.RFC3339),
			first.Open, first.High, first.Low, first.Close, first.BaseVol, first.QuoteVol)
		fmt.Printf("  Last  candle: time=%s  O=%.2f H=%.2f L=%.2f C=%.2f baseVol=%.4f quoteVol=%.4f\n",
			time.UnixMilli(last.OpenTime).UTC().Format(time.RFC3339),
			last.Open, last.High, last.Low, last.Close, last.BaseVol, last.QuoteVol)

		// Compute VWAP
		var totalBase, totalQuote float64
		for _, c := range candles {
			if c.BaseVol > 0 {
				totalBase += c.BaseVol
				totalQuote += c.QuoteVol
			}
		}
		vwap := 0.0
		if totalBase > 0 {
			vwap = totalQuote / totalBase
		}

		fmt.Printf("  VWAP: %.8f\n", vwap)
		fmt.Printf("  Total baseVol: %.4f  quoteVol: %.4f\n\n", totalBase, totalQuote)

		results = append(results, ExchangeResult{
			Name: ex.name, VWAP: vwap, TotalBaseVol: totalBase, TotalQuoteVol: totalQuote,
			LastCandleClose: last.Close, LastCandleTime: last.OpenTime, CandleCount: len(candles),
			Valid: true, RawSize: len(body),
		})
	}

	// Summary
	fmt.Println("========== SUMMARY ==========")
	valid := make([]ExchangeResult, 0)
	for _, r := range results {
		status := "OK"
		if !r.Valid {
			status = "FAIL: " + r.InvalidReason
		}
		fmt.Printf("  %-10s  candles=%2d  VWAP=%.8f  baseVol=%12.4f  status=%s\n",
			r.Name, r.CandleCount, r.VWAP, r.TotalBaseVol, status)
		if r.Valid {
			valid = append(valid, r)
		}
	}

	if len(valid) < 2 {
		fmt.Println("\nNot enough valid exchanges for comparison.")
		return
	}

	// Median VWAP
	vwaps := make([]float64, len(valid))
	for i, r := range valid {
		vwaps[i] = r.VWAP
	}
	sort.Float64s(vwaps)
	median := vwaps[len(vwaps)/2]
	fmt.Printf("\n  Median VWAP: %.8f\n", median)

	// Deviation from median
	fmt.Println("\n  Deviation from median:")
	for _, r := range valid {
		dev := (r.VWAP - median) / median * 100.0
		flag := ""
		if math.Abs(dev) > 2.0 {
			flag = " *** OUTLIER (>2%)"
		}
		fmt.Printf("    %-10s  %.8f  (%+.4f%%)%s\n", r.Name, r.VWAP, dev, flag)
	}

	// Volume-weighted final
	var totalQ, totalB float64
	for _, r := range valid {
		totalQ += r.TotalQuoteVol
		totalB += r.TotalBaseVol
	}
	finalVWAP := totalQ / totalB
	fmt.Printf("\n  Final volume-weighted VWAP: %.8f (priceE8: %d)\n", finalVWAP, int64(math.Round(finalVWAP*1e8)))
}

// --- HTTP ---

func fetchURL(url string) ([]byte, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(body))
	}
	return io.ReadAll(resp.Body)
}

// --- Parsers (same logic as workflow.go) ---

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
		c.QuoteVol = parseJSONFloat(row[7])
		candles = append(candles, c)
	}
	return candles, nil
}

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
			OpenTime: ts, Open: parseFloat(row[1]), High: parseFloat(row[2]),
			Low: parseFloat(row[3]), Close: parseFloat(row[4]),
			BaseVol: parseFloat(row[5]), QuoteVol: parseFloat(row[6]),
		})
	}
	sort.Slice(candles, func(i, j int) bool { return candles[i].OpenTime < candles[j].OpenTime })
	return candles, nil
}

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
			OpenTime: ts, Open: parseFloat(row[1]), High: parseFloat(row[2]),
			Low: parseFloat(row[3]), Close: parseFloat(row[4]),
			BaseVol: parseFloat(row[5]), QuoteVol: parseFloat(row[6]),
		})
	}
	sort.Slice(candles, func(i, j int) bool { return candles[i].OpenTime < candles[j].OpenTime })
	return candles, nil
}

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
			OpenTime: ts * 1000, Open: open, High: high, Low: low,
			Close: closePx, BaseVol: baseVol, QuoteVol: quoteVol,
		})
	}
	sort.Slice(candles, func(i, j int) bool { return candles[i].OpenTime < candles[j].OpenTime })
	return candles, nil
}

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
			OpenTime: ts, Open: parseFloat(row[1]), High: parseFloat(row[2]),
			Low: parseFloat(row[3]), Close: parseFloat(row[4]),
			BaseVol: parseFloat(row[5]), QuoteVol: parseFloat(row[6]),
		})
	}
	sort.Slice(candles, func(i, j int) bool { return candles[i].OpenTime < candles[j].OpenTime })
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

