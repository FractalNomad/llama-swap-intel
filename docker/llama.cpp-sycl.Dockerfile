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
RUN source /opt/intel/oneapi/setvars.sh && \
    cmake -B build \
        -DGGML_SYCL=ON \
        -DCMAKE_C_COMPILER=icx \
        -DCMAKE_CXX_COMPILER=icpx \
        -DLLAMA_OPENSSL=ON && \
    cmake --build build --config Release -j$(nproc)

# Create runtime image
FROM ubuntu:$UBUNTU_VERSION

ARG BUILD_DATE
ARG APP_VERSION
ARG APP_REVISION

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${APP_REVISION}"

# Install oneAPI runtime
RUN apt update && apt install -y libssl-dev curl && \
    rm -rf /var/lib/apt/lists/*

# Copy oneAPI runtime from build stage
COPY --from=build /opt/intel /opt/intel

# Copy built binaries
COPY --from=build /app/llama.cpp/build/bin /app/bin
COPY --from=build /app/llama.cpp/build/lib /app/lib
COPY --from=build /app/llama.cpp/*.py /app/
COPY --from=build /app/llama.cpp/conversion /app/
COPY --from=build /app/llama.cpp/gguf-py /app/

ENV PATH="/app/bin:${PATH}"
ENV LD_LIBRARY_PATH="/app/lib:${LD_LIBRARY_PATH}"

ENTRYPOINT ["/app/bin/llama-server"]
