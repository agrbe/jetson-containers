#!/usr/bin/env bash
set -ex

# upstream tags have no 'v' prefix (e.g. 0.48.0); fail rather than silently build main
git clone --branch=${NVIDIA_MODELOPT_VERSION} --depth=1 \
    https://github.com/NVIDIA/Model-Optimizer /opt/nvidia_modelopt
cd /opt/nvidia_modelopt

# pure-python wheel (py3-none-any); the CUDA extensions ship as sources and are JIT-compiled on first use
uv build --wheel --out-dir ${PIP_WHEEL_DIR} .
uv pip install ${PIP_WHEEL_DIR}/nvidia_modelopt-${NVIDIA_MODELOPT_VERSION}-*.whl

# Optionally upload to a repository using Twine
twine upload --verbose ${PIP_WHEEL_DIR}/nvidia_modelopt-${NVIDIA_MODELOPT_VERSION}-*.whl || echo "Failed to upload wheel to ${TWINE_REPOSITORY_URL}"
