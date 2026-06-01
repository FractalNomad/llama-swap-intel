#!/bin/bash
# Build Mesa Intel Vulkan ICD with VK_NV_cooperative_matrix2 support.
# Installs libvulkan_intel.so + ICD JSON to /install for COPY into runtime image.
# Usage: ./install-mesa.sh <commit_hash|branch|tag>
set -e

COMMIT_HASH="${1:-main}"

mkdir -p /src/mesa
cd /src/mesa

echo "=== Cloning Mesa at ${COMMIT_HASH} ==="
if [ ! -d .git ]; then
    git init
    git remote add origin https://gitlab.freedesktop.org/mesa/mesa.git
fi
git fetch --depth=1 origin "${COMMIT_HASH}"
git checkout FETCH_HEAD

echo "=== Configuring Mesa (Intel Vulkan only) ==="
meson setup builddir/ \
    --prefix=/usr \
    --libdir=lib/x86_64-linux-gnu \
    -Dbuildtype=release \
    -Dgallium-drivers=[] \
    -Dvulkan-drivers=intel \
    -Dopengl=false \
    -Dglx=disabled \
    -Degl=disabled \
    -Dgbm=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled

echo "=== Building Mesa ==="
meson compile -C builddir/ -j"$(nproc)"

echo "=== Installing Mesa to /install ==="
DESTDIR=/install meson install -C builddir/

echo "=== Mesa ICD built successfully ==="
ls -la /install/usr/lib/x86_64-linux-gnu/libvulkan_intel.so
cat /install/usr/share/vulkan/icd.d/intel_icd.x86_64.json
