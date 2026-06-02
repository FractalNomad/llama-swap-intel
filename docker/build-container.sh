#!/bin/bash

set -euo pipefail

cd $(dirname "$0")

# use this to test locally, example:
# LOG_DEBUG=1 DEBUG_ABORT_BUILD=1 ./docker/build-container.sh vulkan
# you need read:package scope on the token. Generate a personal access token with
# the scopes: gist, read:org, repo, write:packages
# then: gh auth login (and copy/paste the new token)

LOG_DEBUG=${LOG_DEBUG:-0}
DEBUG_ABORT_BUILD=${DEBUG_ABORT_BUILD:-}

log_debug() {
    if [ "$LOG_DEBUG" = "1" ]; then
        echo "[DEBUG] $*"
    fi
}

log_info() {
    echo "[INFO] $*"
}

ARCH=$1
PUSH_IMAGES=${2:-false}

# List of allowed architectures
ALLOWED_ARCHS=("vulkan" "sycl")

# Check if ARCH is in the allowed list
if [[ ! " ${ALLOWED_ARCHS[@]} " =~ " ${ARCH} " ]]; then
  log_info "Error: ARCH must be one of the following: ${ALLOWED_ARCHS[@]}"
  exit 1
fi

# Check if GITHUB_TOKEN is set and not empty
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  log_info "Error: GITHUB_TOKEN is not set or is empty."
  exit 1
fi

# LS_REPO is the destination of the built container image — defaults to the
# current GitHub repository so forked CI builds publish to the fork's own
# ghcr.io namespace without code changes. Lowercase for Docker/OCI compliance.
LS_REPO=$(echo "${GITHUB_REPOSITORY:-mostlygeek/llama-swap}" | tr '[:upper:]' '[:lower:]')

# Git hash and build date for embedding in the binary
GIT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Set llama.cpp base image, customizable using the BASE_LLAMACPP_IMAGE environment
# variable, this permits testing with forked llama.cpp repositories
BASE_IMAGE=${BASE_LLAMACPP_IMAGE:-ghcr.io/ggml-org/llama.cpp}

# Fetches the most recent llama.cpp tag matching the given prefix
# Handles pagination to search beyond the first 100 results
# $1 - tag_prefix (e.g., "server" or "server-vulkan")
# Returns: the version number extracted from the tag
fetch_llama_tag() {
    local tag_prefix=$1
    local page=1
    local per_page=100

    while true; do
        log_debug "Fetching page $page for tag prefix: $tag_prefix"

        local response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
            "https://api.github.com/users/ggml-org/packages/container/llama.cpp/versions?per_page=${per_page}&page=${page}")

        # Check for API errors
        if echo "$response" | jq -e '.message' > /dev/null 2>&1; then
            local error_msg=$(echo "$response" | jq -r '.message')
            log_info "GitHub API error: $error_msg"
            return 1
        fi

        # Check if response is empty array (no more pages)
        if [ "$(echo "$response" | jq 'length')" -eq 0 ]; then
            log_debug "No more pages (empty response)"
            return 1
        fi

        # Extract matching tag from this page
        local found_tag=$(echo "$response" | jq -r \
            ".[] | select(.metadata.container.tags[]? | startswith(\"$tag_prefix\")) | .metadata.container.tags[] | select(startswith(\"$tag_prefix\"))" \
            | sort -r | head -n1)

        if [ -n "$found_tag" ]; then
            log_debug "Found tag: $found_tag on page $page"
            echo "$found_tag" | awk -F '-' '{print $NF}'
            return 0
        fi

        page=$((page + 1))

        # Safety limit to prevent infinite loops
        if [ $page -gt 50 ]; then
            log_info "Reached pagination safety limit (50 pages)"
            return 1
        fi
    done
}

if [ "$ARCH" == "sycl" ]; then
    BASE_TAG=sycl
    LCPP_TAG="local"
else
    LCPP_TAG=$(fetch_llama_tag "server-${ARCH}")
    BASE_TAG=server-${ARCH}-${LCPP_TAG}
fi

# Abort if LCPP_TAG is empty (for non-sycl builds).
if [[ "$ARCH" != "sycl" && -z "$LCPP_TAG" ]]; then
    log_info "Abort: Could not find llama-server container for arch: $ARCH"
    exit 1
else
    log_info "LCPP_TAG: $LCPP_TAG"
fi

if [[ ! -z "$DEBUG_ABORT_BUILD" ]]; then
    log_info "Abort: DEBUG_ABORT_BUILD set"
    exit 0
fi

for CONTAINER_TYPE in non-root root; do
  CONTAINER_TAG="ghcr.io/${LS_REPO}:${ARCH}-${LCPP_TAG}"
  CONTAINER_LATEST="ghcr.io/${LS_REPO}:${ARCH}"

  USER_UID=0
  USER_GID=0
  USER_HOME=/root

  if [ "$CONTAINER_TYPE" == "non-root" ]; then
    CONTAINER_TAG="${CONTAINER_TAG}-non-root"
    CONTAINER_LATEST="${CONTAINER_LATEST}-non-root"
    USER_UID=10001
    USER_GID=10001
    USER_HOME=/app
  fi

  log_info "Building $CONTAINER_TYPE $CONTAINER_TAG"

  if [ "$ARCH" == "sycl" ]; then
    # sycl: build everything from source in a single Dockerfile
    # Use buildx with parent dir as context so Go source is available
    docker buildx build --provenance=false \
      --build-context llama-swap=.. \
      --build-arg BUILD_DATE=${BUILD_DATE} \
      --build-arg APP_VERSION=${GIT_HASH:0:8} \
      --build-arg APP_REVISION=${GIT_HASH} \
      --build-arg LLAMA_CPP_REF=${LLAMA_CPP_REF:-master} \
      --build-arg UID=${USER_UID} \
      --build-arg GID=${USER_GID} \
      --build-arg USER_HOME=${USER_HOME} \
      --build-arg GIT_HASH=${GIT_HASH} \
      --build-arg BUILD_DATE_ARG=${BUILD_DATE} \
      -f llama.cpp-sycl.Dockerfile \
      -t ${CONTAINER_TAG} -t ${CONTAINER_LATEST} \
      --load .
  else
    # vulkan: use pre-built llama.cpp image, build llama-swap from source
    docker buildx build --provenance=false \
      --build-context llama-swap=.. \
      --build-arg BASE_IMAGE=${BASE_IMAGE} \
      --build-arg BASE_TAG=${BASE_TAG} \
      --build-arg UID=${USER_UID} \
      --build-arg GID=${USER_GID} \
      --build-arg USER_HOME=${USER_HOME} \
      --build-arg GIT_HASH=${GIT_HASH} \
      --build-arg BUILD_DATE=${BUILD_DATE} \
      -f llama-swap.Containerfile \
      -t ${CONTAINER_TAG} -t ${CONTAINER_LATEST} \
      --load .
  fi

  if [ "$PUSH_IMAGES" == "true" ]; then
    docker push ${CONTAINER_TAG}
    docker push ${CONTAINER_LATEST}
  fi
done
