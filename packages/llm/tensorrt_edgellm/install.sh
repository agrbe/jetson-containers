#!/usr/bin/env bash
set -ex

echo "Installing TensorRT-Edge-LLM ${TENSORRT_EDGELLM_VERSION}"

apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    git
rm -rf /var/lib/apt/lists/*
apt-get autoremove --purge -y
apt-get clean

git clone --branch=${TENSORRT_EDGELLM_BRANCH} --depth=1 --recurse-submodules \
    https://github.com/NVIDIA/TensorRT-Edge-LLM.git ${SOURCE_DIR} || \
git clone --depth=1 --recurse-submodules \
    https://github.com/NVIDIA/TensorRT-Edge-LLM.git ${SOURCE_DIR}

cd ${SOURCE_DIR}

apt-get update
apt-get install -y --no-install-recommends python3-dev
rm -rf /var/lib/apt/lists/*
apt-get clean

# extras deps missing from the image (the rest of [export,tools,server] would downgrade torch/numpy/modelopt)
uv pip install onnxscript==0.7.1 librosa==0.11.0 python-multipart==0.0.32

if [ "$FORCE_BUILD" == "on" ]; then
    echo "Forcing C++ build of TensorRT-Edge-LLM ${TENSORRT_EDGELLM_VERSION}"
    /tmp/tensorrt_edgellm/build.sh
elif uv pip install "tensorrt-edgellm==${TENSORRT_EDGELLM_VERSION}" \
    && python -I -c "import tensorrt_edgellm.runtime as r; r.load()" \
    && TARPACK_PREFIX=${SOURCE_DIR} tarpack install tensorrt-edgellm-${TENSORRT_EDGELLM_VERSION}; then
    # wheel = python package + native payload (pybind runtime, TRT plugin); tarpack = C++ examples
    echo "TensorRT-Edge-LLM ${TENSORRT_EDGELLM_VERSION} installed"
else
    /tmp/tensorrt_edgellm/build.sh
fi

# CLI names dropped the -llm suffix in 0.10 (tensorrt-edgellm-export); accept both.
# Only warn: a broken Python CLI is a dependency issue that the C++ build.sh fallback can't fix.
for cmd in export quantize; do
    tensorrt-edgellm-${cmd} --help || tensorrt-edgellm-${cmd}-llm --help \
        || echo "WARNING: tensorrt-edgellm-${cmd} CLI is not working"
done

touch /tmp/tensorrt_edgellm/.done
