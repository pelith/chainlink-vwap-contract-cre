package main

import (
	"crypto/ecdsa"
	"fmt"
	"os"

	"github.com/ethereum/go-ethereum/crypto"
)

// Derive EVM address from a private key hex string.
// Usage: derive-address <private-key-hex>
func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: derive-address <private-key-hex>\n")
		fmt.Fprintf(os.Stderr, "  Derives the EVM address from a private key.\n")
		fmt.Fprintf(os.Stderr, "  Put the output into config's \"authorizedKeys\".\n")
		os.Exit(1)
	}

	privateKey, err := crypto.HexToECDSA(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid private key: %v\n", err)
		os.Exit(1)
	}

	address := crypto.PubkeyToAddress(*privateKey.Public().(*ecdsa.PublicKey))
	fmt.Println(address.Hex())
}
