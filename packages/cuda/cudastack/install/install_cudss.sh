#!/usr/bin/env bash
set -eux

echo "Installing cuDSS ${CUDSS_VERSION} via network repo"

if [ "$CUDA_ARCH" = "tegra-aarch64" ] && [ "${CUDA_INSTALLED_VERSION}" -lt 132 ]; then
    REPO_ARCH="arm64"
elif [ "$(uname -m)" = "aarch64" ]; then
    REPO_ARCH="sbsa"
else
    REPO_ARCH="x86_64"
fi

cd /tmp

wget $WGET_FLAGS \
    "https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/${REPO_ARCH}/cuda-keyring_1.1-1_all.deb" \
    -O cuda-keyring.deb
dpkg -i cuda-keyring.deb
apt-get update

# Pin the whole CUDA-major chain to CUDSS_VERSION. The 'cudss' meta package only
# requires '>=' versions of its dependencies, so pinning it alone pulls the newest
# release (1.x ships libcudss.so.1) plus the CUDA 12 build.
CUDSS_APT_VER=$(apt-cache madison "cudss-cuda-${CUDA_VERSION_MAJOR}" 2>/dev/null \
    | awk -v ver="${CUDSS_VERSION}." '{gsub(/ /, "", $3)} index($3, ver) == 1 {print $3; exit}')

if [ -z "${CUDSS_APT_VER}" ]; then
    echo "cudss-cuda-${CUDA_VERSION_MAJOR} ${CUDSS_VERSION} not found in the repo" >&2
    exit 1
fi

echo "Pinning cuDSS to version: ${CUDSS_APT_VER}"
CUDSS_SONAME="${CUDSS_VERSION%%.*}"
apt-get install -y --no-install-recommends \
    "cudss-cuda-${CUDA_VERSION_MAJOR}=${CUDSS_APT_VER}" \
    "libcudss${CUDSS_SONAME}-cuda-${CUDA_VERSION_MAJOR}=${CUDSS_APT_VER}" \
    "libcudss${CUDSS_SONAME}-dev-cuda-${CUDA_VERSION_MAJOR}=${CUDSS_APT_VER}" \
    "libcudss${CUDSS_SONAME}-static-cuda-${CUDA_VERSION_MAJOR}=${CUDSS_APT_VER}"

# Remove cuda-keyring to prevent the global NVIDIA repo from propagating
# to subsequent build layers (preserves version control of installed packages)
dpkg --purge cuda-keyring 2>/dev/null || true
rm -f /etc/apt/sources.list.d/cuda-*-keyring.list
rm -f /etc/apt/preferences.d/cuda-repository-pin-600
rm -f /usr/share/keyrings/cuda-archive-keyring.gpg

rm -f /tmp/cuda-keyring.deb
rm -rf /var/lib/apt/lists/*
apt-get clean
rm -rf /tmp/*.deb
rm -rf /*.deb

echo "cuDSS ${CUDSS_VERSION} installed successfully"
