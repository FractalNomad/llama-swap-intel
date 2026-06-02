#!/bin/bash
# Build llama-swap from source
# Usage: ./build-llama-swap.sh [git_ref]
#   git_ref: git branch, tag, or commit hash (default: "main")
set -e

GIT_REF="${1:-main}"
REPO="https://github.com/mostlygeek/llama-swap.git"

mkdir -p /install/bin

echo "=== Building llama-swap from source (ref: ${GIT_REF}) ==="

# Clone llama-swap source
LLAMA_SWAP_DIR=/src/llama-swap
if [ ! -d "${LLAMA_SWAP_DIR}" ]; then
    git clone --depth 1 --branch "${GIT_REF}" "${REPO}" "${LLAMA_SWAP_DIR}"
fi

cd "${LLAMA_SWAP_DIR}"

# Get version info
GIT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build llama-swap
CGO_ENABLED=0 go build \
    -ldflags="-X main.commit=${GIT_HASH} -X main.version=${GIT_HASH} -X main.date=${BUILD_DATE}" \
    -o /install/bin/llama-swap

# Validate
if [ ! -x "/install/bin/llama-swap" ]; then
    echo "FATAL: llama-swap binary not found or not executable" >&2
    ls -la /install/bin/ >&2
    exit 1
fi

echo "$GIT_HASH" > /install/llama-swap-version

echo "=== llama-swap ${GIT_HASH:0:7} built ==="
ls -la /install/bin/llama-swap
