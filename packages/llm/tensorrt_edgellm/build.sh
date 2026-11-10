#!/usr/bin/env bash
set -ex

echo "Building TensorRT-Edge-LLM ${TENSORRT_EDGELLM_VERSION} wheel"

cd ${SOURCE_DIR}

# TensorRT Package
TRT_PACKAGE_DIR="/usr"

if [ ! -d "${TRT_PACKAGE_DIR}/include" ] || [ ! -d "${TRT_PACKAGE_DIR}/lib" ]; then
    echo "TensorRT not found at ${TRT_PACKAGE_DIR}, searching..."
    TRT_DIR=$(find /usr/local -maxdepth 1 -name "TensorRT*" -type d | head -1)
    if [ -n "$TRT_DIR" ]; then
        TRT_PACKAGE_DIR="$TRT_DIR"
    fi
fi

# Upstream wheel flow (packaging/README.md, "Build for the current target").
# The pinned packaging toolchain goes in its own venv so the image keeps its cmake/wheel/build.
WHEEL_VENV=/tmp/tensorrt_edgellm/venv
uv venv --clear ${WHEEL_VENV}
uv pip install --python ${WHEEL_VENV} -r packaging/wheel-toolchain-requirements.txt

# The base image's LDFLAGS carries -Wl,-rpath,/usr/local/cuda/lib64; the payload audit only
# accepts $ORIGIN rpaths (CUDA/TensorRT resolve through ldconfig at runtime).
export LDFLAGS=$(echo ${LDFLAGS} | sed 's/-Wl,-rpath,[^ ]*//g')

# --local selects the packaging/variants.toml row of this device (jetson-orin-jp72-cu13-sm87),
# extracts the checksum-verified CuTe DSL tarball shipped in kernelSrcs/cuteDSLPrebuilt,
# builds the pybind runtime + TensorRT plugin, audits them, and assembles a wheel
# with tensorrt_edgellm/_native/variants.json + payload (build tag 1subset<hash>).
PATH=${WHEEL_VENV}/bin:${PATH} python packaging/wheel_cli.py build-wheel \
    --local \
    --trt-package-dir ${TRT_PACKAGE_DIR} \
    --output-dir dist/wheel

# The C++ examples (llm_build, llm_inference, ...) are not in the wheel:
# build the remaining targets of the same CMake tree and keep the old build/ layout.
BUILD_TREE=$(echo build/wheel/*)
PATH=${WHEEL_VENV}/bin:${PATH} cmake --build ${BUILD_TREE} --parallel $(nproc)
ln -sfn ${BUILD_TREE#build/}/examples build/examples
ln -sfn ${BUILD_TREE#build/}/libNvInfer_edgellm_plugin.so build/libNvInfer_edgellm_plugin.so

mkdir -p ${PIP_WHEEL_DIR}
cp dist/wheel/tensorrt_edgellm-*.whl ${PIP_WHEEL_DIR}/
uv pip install --reinstall-package tensorrt-edgellm dist/wheel/tensorrt_edgellm-*.whl

twine upload --verbose dist/wheel/tensorrt_edgellm-*.whl || echo "failed to upload wheel to ${TWINE_REPOSITORY_URL}"
tarpack upload tensorrt-edgellm-${TENSORRT_EDGELLM_VERSION} ${SOURCE_DIR} || echo "failed to upload tarball"

echo "TensorRT-Edge-LLM build complete"
ls -la build/examples/llm/ build/examples/multimodal/

touch /tmp/tensorrt_edgellm/.done
