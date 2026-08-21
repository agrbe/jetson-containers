#!/usr/bin/env bash
set -ex

echo "Detected architecture: ${CUDA_ARCH}"

apt-get update
apt-get install -y --no-install-recommends \
        binutils \
        xz-utils
rm -rf /var/lib/apt/lists/*
apt-get clean

echo "Downloading ${CUDA_DEB}"
mkdir -p /tmp/cuda
cd /tmp/cuda

if [[ "$CUDA_ARCH" == "tegra-aarch64" ]]; then
    # Jetson (Tegra)
    wget $WGET_FLAGS \
        https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/arm64/cuda-${DISTRO}.pin \
        -O /etc/apt/preferences.d/cuda-repository-pin-600
else
    # ARM64 SBSA (Grace)
    wget $WGET_FLAGS \
        https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/sbsa/cuda-${DISTRO}.pin \
        -O /etc/apt/preferences.d/cuda-repository-pin-600
fi

wget $WGET_FLAGS ${CUDA_URL}
dpkg -i *.deb
cp /var/cuda-*-local/cuda-*-keyring.gpg /usr/share/keyrings/

# Tegra (Jetson)
if [[ "$CUDA_ARCH" == "tegra-aarch64" ]]; then
    if [[ -f /var/cuda-tegra-repo-ubuntu*-local/cuda-compat-*.deb ]]; then
        ar x /var/cuda-tegra-repo-ubuntu*-local/cuda-compat-*.deb
        tar xvf data.tar.xz -C /
    fi
fi

apt-get update
apt-get install -y --no-install-recommends ${CUDA_PACKAGES}
rm -rf /var/lib/apt/lists/*
apt-get clean

dpkg --list | grep cuda
dpkg -P ${CUDA_DEB}
rm -rf /tmp/cuda

# --- CCCL hotfix (NVIDIA/cccl #8842 + GCC 13.3) ------------------------------
# CUDA 13.2 bundles CCCL headers declaring specializations of
# cuda::proclaims_copyable_arguments with qualified names that GCC 13.3
# rejects (both the original '::cuda::' and the upstream-fixed 'cuda::').
# Rewrite to the namespace-wrapped form: same declaration, same semantics,
# same optimization opt-in — only the invalid syntax changes. No compiler
# flags altered. Idempotent and self-retiring (no-op on fixed toolkits).
CUDA_REAL="$(readlink -f /usr/local/cuda)"
CCCL_HITS="$(grep -rlE 'struct (::)?cuda::proclaims_copyable_arguments' "$CUDA_REAL" \
    --include='*.cuh' --include='*.h' --include='*.inl' || true)"
if [ -n "$CCCL_HITS" ]; then
    echo "CCCL hotfix: patching:"; echo "$CCCL_HITS"
    echo "$CCCL_HITS" | xargs -r perl -0777 -pi -e '
      s/(template <[^>]*>)\s*\nstruct (?:::)?cuda::proclaims_copyable_arguments<(.*?)>(.*?)\{\};/namespace cuda {\n$1\nstruct proclaims_copyable_arguments<$2>$3\{\};\n} \/\/ namespace cuda (jetson hotfix)/gs'
else
    echo "CCCL hotfix: nothing to patch (headers already clean)"
fi
echo "CCCL hotfix: verifying..."
if grep -rqE 'struct (::)?cuda::proclaims_copyable_arguments' "$CUDA_REAL" \
    --include='*.cuh' --include='*.h' --include='*.inl'; then
    echo "CCCL hotfix: FAILED — qualified specializations remain:"
    grep -rnE 'struct (::)?cuda::proclaims_copyable_arguments' "$CUDA_REAL" \
        --include='*.cuh' --include='*.h' --include='*.inl'
    exit 1
fi
echo "CCCL hotfix: OK"
# -----------------------------------------------------------------------------
