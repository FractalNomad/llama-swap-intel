ARG BASE_IMAGE=ghcr.io/ggml-org/llama.cpp
ARG BASE_TAG=server-cuda
FROM ${BASE_IMAGE}:${BASE_TAG}

# Build llama-swap from source
FROM golang:1.26-bookworm AS build
ARG TARGETARCH=amd64
ARG GIT_HASH=unknown
ARG BUILD_DATE=unknown
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY --from=llama-swap . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build \
    -ldflags="-X main.commit=${GIT_HASH} -X main.version=${GIT_HASH} -X main.date=${BUILD_DATE}" \
    -o /out/llama-swap

# Runtime image
FROM ${BASE_IMAGE}:${BASE_TAG}

# Set default UID/GID arguments
ARG UID=10001
ARG GID=10001
ARG USER_HOME=/app

# Add user/group
ENV HOME=$USER_HOME
RUN if [ $UID -ne 0 ]; then \
      if [ $GID -ne 0 ]; then \
        groupadd --system --gid $GID app; \
      fi; \
      useradd --system --uid $UID --gid $GID \
      --home $USER_HOME app; \
    fi

# Handle paths
RUN mkdir --parents $HOME /app
RUN chown --recursive $UID:$GID $HOME /app

# Switch user
USER $UID:$GID

WORKDIR /app

# Add /app to PATH
ENV PATH="/app:${PATH}"

# Copy built binary
COPY --from=build --chown=$UID:$GID /out/llama-swap /app/llama-swap

COPY --chown=$UID:$GID config.example.yaml /app/config.yaml

HEALTHCHECK CMD curl -f http://localhost:8080/ || exit 1
ENTRYPOINT [ "/app/llama-swap", "-config", "/app/config.yaml" ]
