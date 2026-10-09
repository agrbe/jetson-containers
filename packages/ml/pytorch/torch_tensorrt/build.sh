#!/usr/bin/env bash
# Build torch_tensorrt from source (SBSA config) against:
#   - libtorch : the torch in the venv (MODULE.bazel local_torch(); TORCH_PATH pins it)
#   - TensorRT : the system install via ${TRT_SHIM} (replaces the http_archive tarball download)
#   - CUDA     : /usr/local/cuda (upstream hardcodes /usr/local/cuda-13.0)
set -ex
echo "Building torch_tensorrt ${TORCH_TRT_VERSION}"

case "${TORCH_TRT_VERSION}" in
    v[0-9]*) export RELEASE=1 BUILD_VERSION="${TORCH_TRT_VERSION#v}" ;;
esac
export TORCH_PATH="$(python3 -c 'import os, torch; print(os.path.dirname(torch.__file__))')"
echo "TORCH_PATH=${TORCH_PATH}  RELEASE=${RELEASE:-0}  BUILD_VERSION=${BUILD_VERSION:-<dev0+sha>}"

uv pip install pyyaml

cd /tmp
git clone --branch=${TORCH_TRT_VERSION} --depth=1 https://github.com/pytorch/TensorRT torch_tensorrt || \
git clone --depth=1 https://github.com/pytorch/TensorRT torch_tensorrt
cd /tmp/torch_tensorrt

# CUDA: /usr/local/cuda-13.0 -> /usr/local/cuda
grep -rl 'cuda-13\.0' --include='MODULE.bazel' --include='WORKSPACE*' --include='*.bzl' . | \
    xargs -r sed -i 's|/usr/local/cuda-13.0|/usr/local/cuda|g'

# TensorRT: replace the tensorrt_sbsa http_archive with the local install (same archive:BUILD layout)
perl -0pi -e 's|http_archive\(\n\s*name = "tensorrt_sbsa",.*?\n\)|new_local_repository(\n    name = "tensorrt_sbsa",\n    build_file = "@//third_party/tensorrt/archive:BUILD",\n    path = "$ENV{TRT_SHIM}",\n)|s' MODULE.bazel
grep -q "path = \"${TRT_SHIM}\"" MODULE.bazel
echo "== MODULE.bazel patched =="
grep -n -B1 -A4 'name = "tensorrt_sbsa"' MODULE.bazel
grep -n '/usr/local/cuda' MODULE.bazel

# Wheel metadata: drop the PyPI `tensorrt` dependency (it pulls tensorrt-cu13-libs, a second copy of
# libnvinfer) and the optional executorch backend (pulls ~10 heavy packages).
sed -i '/^def get_sbsa_requirements/,/^def /{/"tensorrt>=10\.16\.1,<10\.17\.0",/d;/EXECUTORCH_REQUIREMENT,/d}' setup.py
echo "== get_sbsa_requirements after patch =="
sed -n '/^def get_sbsa_requirements/,/^def get_x86_64_requirements/p' setup.py

python3 setup.py bdist_wheel
cp dist/torch_tensorrt*.whl /opt
cd /
rm -rf /tmp/torch_tensorrt /root/.cache/bazel

# install + verify the local wheel, and only upload it if that passes
WHEEL="$(ls /opt/torch_tensorrt*.whl | head -1)"
"$(dirname "$(readlink -f "$0")")/install.sh" "$WHEEL"

twine upload --verbose /opt/torch_tensorrt*.whl || echo "failed to upload wheel to ${TWINE_REPOSITORY_URL}"
