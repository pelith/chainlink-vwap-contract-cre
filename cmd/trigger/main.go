package main

import (
	"bytes"
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/ethereum/go-ethereum/crypto"
)

// SettlementRequest matches the CRE workflow payload
type SettlementRequest struct {
	StartTime int64 `json:"startTime"`
	EndTime   int64 `json:"endTime"`
}

func main() {
	// Usage: trigger [timestamp]
	//   No args  → use current time (for cron-like manual run)
	//   1 arg    → use given unix timestamp
	// In both cases: endTime = floor(t, hour), startTime = endTime - 12h

	var refTime int64
	switch len(os.Args) {
	case 1:
		refTime = time.Now().Unix()
	case 2:
		t, err := strconv.ParseInt(os.Args[1], 10, 64)
		if err != nil {
			fmt.Fprintf(os.Stderr, "invalid timestamp: %v\n", err)
			os.Exit(1)
		}
		refTime = t
	default:
		fmt.Fprintf(os.Stderr, "Usage: trigger [timestamp]\n")
		fmt.Fprintf(os.Stderr, "  No args  → current time\n")
		fmt.Fprintf(os.Stderr, "  1 arg    → unix timestamp (e.g. 1740042720 for 7:12)\n")
		fmt.Fprintf(os.Stderr, "  endTime  = floor(timestamp, 1h)\n")
		fmt.Fprintf(os.Stderr, "  startTime = endTime - 12h\n")
		fmt.Fprintf(os.Stderr, "\nEnvironment: BACKEND_PRIVATE_KEY, CRE_ENDPOINT_URL\n")
		os.Exit(1)
	}

	// Floor to hour boundary
	endTime := (refTime / 3600) * 3600
	startTime := endTime - 12*3600

	privKeyHex := os.Getenv("BACKEND_PRIVATE_KEY")
	if privKeyHex == "" {
		fmt.Fprintf(os.Stderr, "BACKEND_PRIVATE_KEY not set\n")
		os.Exit(1)
	}

	endpoint := os.Getenv("CRE_ENDPOINT_URL")
	if endpoint == "" {
		fmt.Fprintf(os.Stderr, "CRE_ENDPOINT_URL not set\n")
		os.Exit(1)
	}

	privateKey, err := crypto.HexToECDSA(privKeyHex)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid private key: %v\n", err)
		os.Exit(1)
	}

	publicKey := privateKey.Public().(*ecdsa.PublicKey)
	signerAddress := crypto.PubkeyToAddress(*publicKey)

	req := SettlementRequest{
		StartTime: startTime,
		EndTime:   endTime,
	}
	payload, err := json.Marshal(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal payload: %v\n", err)
		os.Exit(1)
	}

	hash := crypto.Keccak256Hash(payload)
	signature, err := crypto.Sign(hash.Bytes(), privateKey)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to sign: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("=== CRE HTTP Trigger ===")
	fmt.Printf("Endpoint:  %s\n", endpoint)
	fmt.Printf("Signer:    %s\n", signerAddress.Hex())
	fmt.Printf("StartTime: %d (%s UTC)\n", startTime, time.Unix(startTime, 0).UTC().Format("2006-01-02 15:04"))
	fmt.Printf("EndTime:   %d (%s UTC)\n", endTime, time.Unix(endTime, 0).UTC().Format("2006-01-02 15:04"))
	fmt.Printf("Payload:   %s\n", string(payload))
	fmt.Printf("Signature: 0x%x\n", signature)
	fmt.Println()

	httpReq, err := http.NewRequest("POST", endpoint, bytes.NewReader(payload))
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create request: %v\n", err)
		os.Exit(1)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("X-Signature", fmt.Sprintf("0x%x", signature))
	httpReq.Header.Set("X-Signer", signerAddress.Hex())

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(httpReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "request failed: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	fmt.Printf("Status: %d\n", resp.StatusCode)
	fmt.Printf("Response: %s\n", string(body))

	if resp.StatusCode >= 400 {
		os.Exit(1)
	}
}
