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

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// SettlementRequest matches the CRE workflow payload
type SettlementRequest struct {
	OrderID   string `json:"orderId"`
	StartTime int64  `json:"startTime"`
	EndTime   int64  `json:"endTime"`
}

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintf(os.Stderr, "Usage: trigger <orderId> <startTime> <endTime>\n")
		fmt.Fprintf(os.Stderr, "  Environment: BACKEND_PRIVATE_KEY, CRE_ENDPOINT_URL\n")
		fmt.Fprintf(os.Stderr, "\nExample:\n")
		fmt.Fprintf(os.Stderr, "  trigger 1 1739552400 1739595600\n")
		os.Exit(1)
	}

	orderId := os.Args[1]
	startTime, err := strconv.ParseInt(os.Args[2], 10, 64)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid startTime: %v\n", err)
		os.Exit(1)
	}
	endTime, err := strconv.ParseInt(os.Args[3], 10, 64)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid endTime: %v\n", err)
		os.Exit(1)
	}

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

	// Parse private key
	privateKey, err := crypto.HexToECDSA(privKeyHex)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid private key: %v\n", err)
		os.Exit(1)
	}

	publicKey := privateKey.Public().(*ecdsa.PublicKey)
	signerAddress := crypto.PubkeyToAddress(*publicKey)

	// Build payload
	req := SettlementRequest{
		OrderID:   orderId,
		StartTime: startTime,
		EndTime:   endTime,
	}
	payload, err := json.Marshal(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal payload: %v\n", err)
		os.Exit(1)
	}

	// Sign: keccak256(payload) → ECDSA sign
	hash := crypto.Keccak256Hash(payload)
	signature, err := crypto.Sign(hash.Bytes(), privateKey)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to sign: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("=== CRE HTTP Trigger ===")
	fmt.Printf("Endpoint:  %s\n", endpoint)
	fmt.Printf("Signer:    %s\n", signerAddress.Hex())
	fmt.Printf("Payload:   %s\n", string(payload))
	fmt.Printf("Hash:      %s\n", hash.Hex())
	fmt.Printf("Signature: 0x%x\n", signature)
	fmt.Println()

	// Send HTTP POST
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

// deriveAddress is a helper for printing the signer address from a private key
func deriveAddress(privateKey *ecdsa.PrivateKey) common.Address {
	return crypto.PubkeyToAddress(*privateKey.Public().(*ecdsa.PublicKey))
}
