#!/usr/bin/env bash
set -ex

echo "Building TensorRT-Edge-LLM C++ runtime ${TENSORRT_EDGELLM_VERSION}"

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

# CuTe DSL Kernel Build
uv pip install "nvidia-cutlass-dsl[cu13]==4.7.0" cupy-cuda13x==13.6.0
echo "Building CuTe DSL..."
python kernelSrcs/build_cutedsl.py --gpu_arch sm_87 --cuda-version ${CUDA_VERSION}

# Python frontend
PYBIND="$(python -m pybind11 --cmakedir)"

CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release
            -DTRT_PACKAGE_DIR=${TRT_PACKAGE_DIR}
            -DCUDA_CTK_VERSION=${CUDA_VERSION}
            -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES}
            -DBUILD_PYTHON_BINDINGS=ON
            -Dpybind11_DIR=${PYBIND}
            -DEMBEDDED_TARGET=jetson-orin
            -DENABLE_CUTE_DSL=ALL
            -DCUDA_DRIVER_LIB=/usr/local/cuda/lib64/stubs/libcuda.so"

ARCH=$(uname -m)
# if [ "$ARCH" = "aarch64" ]; then
#     if [ -f cmake/aarch64_linux_toolchain.cmake ]; then
#         CMAKE_ARGS="${CMAKE_ARGS} -DCMAKE_TOOLCHAIN_FILE=cmake/aarch64_linux_toolchain.cmake"
#     fi
# fi

mkdir -p build
cd build

cmake .. ${CMAKE_ARGS}
make -j$(nproc)

cmake --install . --prefix ${SOURCE_DIR}/dist 2>&1 | tail -5 || {
    mkdir -p ${SOURCE_DIR}/bin
    cp examples/llm/{llm_build,llm_inference,llm_stream,llm_bench} ${SOURCE_DIR}/bin/
    cp examples/multimodal/{audio_build,visual_build,action_build,action_inference} ${SOURCE_DIR}/bin/ 2>/dev/null || true
}

uv build --wheel --out-dir $PIP_WHEEL_DIR ${SOURCE_DIR}
uv pip install ${SOURCE_DIR}

twine upload --verbose $PIP_WHEEL_DIR/tensorrt_edgellm-*.whl || echo "failed to upload wheel to ${TWINE_REPOSITORY_URL}"
tarpack upload tensorrt-edgellm-${TENSORRT_EDGELLM_VERSION} ${SOURCE_DIR} || echo "failed to upload tarball"

echo "TensorRT-Edge-LLM C++ build complete"
ls -la examples/llm/ 2>/dev/null || true
ls -la examples/multimodal/ 2>/dev/null || true

touch /tmp/tensorrt_edgellm/.done
