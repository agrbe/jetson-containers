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

sed -i -E 's|(torch)[~=]=|\1>=|g; s|(transformers)[~=]=|\1>=|g' requirements.txt pyproject.toml

uv pip install .

tensorrt-edgellm-export-llm --help
tensorrt-edgellm-quantize-llm --help

if [ "$FORCE_BUILD" == "on" ]; then
    echo "Forcing C++ build of TensorRT-Edge-LLM ${TENSORRT_EDGELLM_VERSION}"
    /tmp/tensorrt_edgellm/build.sh
elif TARPACK_PREFIX=${SOURCE_DIR} tarpack install tensorrt-edgellm-${TENSORRT_EDGELLM_VERSION} \
    && uv pip install $SOURCE_DIR; then
    echo "TensorRT-Edge-LLM C++ ${TENSORRT_EDGELLM_VERSION} installed"
else
    /tmp/tensorrt_edgellm/build.sh
fi

touch /tmp/tensorrt_edgellm/.done
