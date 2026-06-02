# syntax=docker/dockerfile:1
ARG UBUNTU_VERSION=26.04
ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A

FROM ubuntu:$UBUNTU_VERSION AS build

# Install build tools
RUN apt update && apt install -y git build-essential cmake wget xz-utils

# Install SSL and oneAPI SDK dependencies
RUN apt install -y libssl-dev curl

# Install oneAPI
ARG ONEAPI_VERSION=2025.3.3
ARG ONEAPI_INSTALLER=intel-deep-learning-essentials-${ONEAPI_VERSION}.16_offline.sh
ARG ONEAPI_URL=https://registrationcenter-download.intel.com/akdlm/IRC_NAS/56f7923a-adb8-43f3-8b02-2b60fcac8cab/${ONEAPI_INSTALLER}

RUN wget -q "${ONEAPI_URL}" -O /tmp/${ONEAPI_INSTALLER} && \
    sh /tmp/${ONEAPI_INSTALLER} -s -a --silent --eula accept && \
    rm /tmp/${ONEAPI_INSTALLER}

# Clone llama.cpp
ARG LLAMA_CPP_REF=master
RUN git clone --depth 1 --branch ${LLAMA_CPP_REF} https://github.com/ggml-org/llama.cpp.git /app/llama.cpp

# Build llama.cpp with SYCL
WORKDIR /app/llama.cpp
RUN . /opt/intel/oneapi/setvars.sh && \
    cmake -B build \
        -DGGML_SYCL=ON \
        -DCMAKE_C_COMPILER=icx \
        -DCMAKE_CXX_COMPILER=icpx \
        -DLLAMA_OPENSSL=ON && \
    cmake --build build --config Release -j$(nproc)

# Build llama-swap from source
FROM golang:1.26-bookworm AS ls-build
ARG GIT_HASH=unknown
ARG BUILD_DATE=unknown
WORKDIR /src
COPY --from=llama-swap go.mod go.sum ./
RUN go mod download
COPY --from=llama-swap . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-X main.commit=${GIT_HASH} -X main.version=${GIT_HASH} -X main.date=${BUILD_DATE}" \
    -o /out/llama-swap

# Create runtime image
FROM ubuntu:$UBUNTU_VERSION

ARG BUILD_DATE
ARG APP_VERSION
ARG APP_REVISION

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${APP_REVISION}"

# Install oneAPI runtime and user management tools
RUN apt update && apt install -y libssl-dev curl && \
    rm -rf /var/lib/apt/lists/*

# Copy oneAPI runtime from build stage
COPY --from=build /opt/intel /opt/intel

# Set up oneAPI environment
ENV PATH="/opt/intel/oneapi/setvars.sh:${PATH}"

# Set up user
ARG UID=10001
ARG GID=10001
ARG USER_HOME=/app
ENV HOME=$USER_HOME
RUN if [ $UID -ne 0 ]; then \
      groupadd --system --gid $GID app && \
      useradd --system --uid $UID --gid $GID --home $USER_HOME app; \
    fi
RUN mkdir --parents $HOME /app
RUN chown --recursive $UID:$GID $HOME /app
USER $UID:$GID
WORKDIR /app

# Copy llama.cpp SYCL binaries
COPY --from=build /app/llama.cpp/build/bin/llama-server /app/llama-server
COPY --from=build /app/llama.cpp/build/bin/llama-cli /app/llama-cli
COPY --from=build /app/llama.cpp/build/bin/llama-quantize /app/llama-quantize
COPY --from=build /app/llama.cpp/build/bin/llama-bench /app/llama-bench

# Copy llama-swap
COPY --from=ls-build /out/llama-swap /app/llama-swap

# Add to PATH
ENV PATH="/app:${PATH}"

# Copy config
COPY config.example.yaml /app/config.yaml

HEALTHCHECK CMD curl -f http://localhost:8080/ || exit 1
ENTRYPOINT ["/app/llama-swap", "-config", "/app/config.yaml"]