# Settler HTTP server
#
# Exposes POST /settle — runs `cre workflow simulate` then forwards rawReport on-chain.
# Requires the `cre` CLI to be installed (see installation note below).
#
# Build:
#   docker build -t vwap-settler .
#
# Run:
#   docker run -p 8081:8081 \
#     -e RPC_URL=... \
#     -e MANUAL_ORACLE_ADDRESS=0x... \
#     -e DEPLOYER_PRIVATE_KEY=0x... \
#     vwap-settler

# ---- Stage 1: Build the settler binary ----
FROM golang:1.25.3 AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o settler ./cmd/server

# ---- Stage 2: Runtime ----
#
# We use golang:1.25.3 (not scratch) because:
#   1. `cre workflow simulate` compiles workflow.go → WASM at runtime (needs Go toolchain)
#   2. `cre` CLI itself may have dynamic dependencies
#
# Install cre CLI:
#   Follow https://docs.chain.link/cre/getting-started/installation
#   Typically: go install github.com/smartcontractkit/cre@latest
#   Or: download binary from GitHub releases and copy to /usr/local/bin/cre
#
FROM golang:1.25.3

# Install cre CLI via go install
# This requires network access during docker build.
RUN go install github.com/smartcontractkit/cre@latest 2>/dev/null || true
# If go install doesn't work, download the binary manually:
# COPY cre /usr/local/bin/cre
# RUN chmod +x /usr/local/bin/cre

WORKDIR /app

# Copy the pre-built settler binary
COPY --from=builder /app/settler /app/settler

# Copy workflow files needed by `cre workflow simulate`
COPY vwap-eth-quote-flow/ ./vwap-eth-quote-flow/
COPY project.yaml .

# CRE_REPO_DIR tells the settler where to run `cre workflow simulate` from
ENV CRE_REPO_DIR=/app
ENV SETTLER_ADDR=:8081

EXPOSE 8081

ENTRYPOINT ["/app/settler"]
