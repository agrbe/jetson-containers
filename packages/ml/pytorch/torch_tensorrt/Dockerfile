#---
# name: torch_tensorrt
# group: pytorch
# config: config.py
# depends: [pytorch, torchvision, cudastack:standard, bazel]
# buildkit_device: nvidia.com/gpu=all
# test: [test.py, test.sh]
# notes: https://pytorch.org/TensorRT/getting_started/installation.html#installation
#---
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# JETPACK_MAJOR / JETPACK_MINOR are still passed by config.py but unused here:
# upstream's `--config=jetpack` is JetPack 6 only (TensorRT 10.3 / torch 2.8 / CUDA 12.6).
# On JetPack 7.x the build uses the SBSA path, linked against the TensorRT that
# cudastack already installed in this image (tarball layout: headers in /usr/include,
# libs in /usr/local/cuda/targets/aarch64-linux/lib on Tegra, /usr/lib/aarch64-linux-gnu on SBSA).
ARG JETPACK_MAJOR \
    JETPACK_MINOR \
    PYTHON_VERSION=3.12 \
    TORCH_TRT_VERSION=main

ARG VENV_DIR=/opt/venv \
    TRT_SHIM=/opt/tensorrt

# Locate the TensorRT install (JetPack .deb layout via tensorrt:jetpack, or the cudastack
# tarball layout) and expose it in the flat include/ + lib/
# layout that upstream's third_party/tensorrt/archive:BUILD expects. Fail fast if missing.
RUN set -e; \
    TRT_LIB="$(ldconfig -p | awk '/libnvinfer\.so\.10 /{print $NF; exit}')"; \
    [ -n "$TRT_LIB" ] || TRT_LIB="$(find /usr/local/cuda/targets /usr/lib/aarch64-linux-gnu /usr/local/lib -name 'libnvinfer.so.10' 2>/dev/null | head -1)"; \
    [ -n "$TRT_LIB" ] || { echo "ERROR: libnvinfer.so.10 not found; base image lacks TensorRT (cudastack WITH_TENSORRT=1)" >&2; exit 1; }; \
    TRT_LIB_DIR="$(dirname "$TRT_LIB")"; \
    TRT_INC_DIR="$(dirname "$(find /usr/include -maxdepth 2 -name NvInfer.h -print -quit 2>/dev/null)")"; \
    [ -e "$TRT_INC_DIR/NvInfer.h" ] || { echo "ERROR: NvInfer.h not found under /usr/include; TensorRT headers missing in base image" >&2; exit 1; }; \
    [ -e "$TRT_INC_DIR/NvInferPlugin.h" ] || { echo "ERROR: $TRT_INC_DIR/NvInferPlugin.h not found" >&2; exit 1; }; \
    mkdir -p ${TRT_SHIM}/include ${TRT_SHIM}/lib; \
    for h in "$TRT_INC_DIR"/Nv*.h; do ln -sf "$h" ${TRT_SHIM}/include/; done; \
    for l in "$TRT_LIB_DIR"/libnv*.so*; do ln -sf "$l" ${TRT_SHIM}/lib/; done; \
    for base in libnvinfer libnvinfer_plugin libnvonnxparser; do \
        [ -e ${TRT_SHIM}/lib/${base}.so ] || { [ -e "$TRT_LIB_DIR/${base}.so.10" ] && ln -s "$TRT_LIB_DIR/${base}.so.10" ${TRT_SHIM}/lib/${base}.so; } || true; \
    done; \
    [ -e ${TRT_SHIM}/lib/libnvinfer.so ] && [ -e ${TRT_SHIM}/lib/libnvinfer_plugin.so ] || { echo "ERROR: could not create libnvinfer.so / libnvinfer_plugin.so links in ${TRT_SHIM}/lib" >&2; exit 1; }; \
    # libnvinfer dlopen()s libnvinfer_builder_resource_smXX.so.<version> by file name. Their SONAME is
    # "do_not_link_against_*", so ld.so.cache cannot resolve them, and the tarball dir is not on
    # LD_LIBRARY_PATH nor a default loader dir -> engine builds fail on Orin (sm86 family). Default
    # loader dirs are searched by file name, so link the resources there.
    if [ "$TRT_LIB_DIR" != /usr/lib/aarch64-linux-gnu ]; then \
        for r in "$TRT_LIB_DIR"/libnvinfer_builder_resource*.so*; do [ -e "$r" ] && ln -sfn "$r" /usr/lib/aarch64-linux-gnu/; done; \
        ldconfig; \
    fi; \
    ls /usr/lib/aarch64-linux-gnu/libnvinfer_builder_resource_sm86* >/dev/null 2>&1 || { echo "ERROR: libnvinfer_builder_resource_sm86 not reachable by the loader" >&2; exit 1; }; \
    echo "TensorRT libs : $TRT_LIB_DIR"; \
    echo "TensorRT hdrs : $TRT_INC_DIR"; \
    echo "TensorRT ver  : $(grep -h 'define NV_TENSORRT_\(MAJOR\|MINOR\|PATCH\|BUILD\)' "$TRT_INC_DIR/NvInferVersion.h" | awk '{print $3}' | paste -sd.)"; \
    ls -l ${TRT_SHIM}/lib/libnvinfer.so ${TRT_SHIM}/lib/libnvinfer_plugin.so

# Build torch_tensorrt from source (SBSA config) against:
#   - libtorch : the torch in the venv (MODULE.bazel local_torch(); TORCH_PATH pins it)
#   - TensorRT : the system install via ${TRT_SHIM} (replaces the http_archive tarball download)
#   - CUDA     : /usr/local/cuda (upstream hardcodes /usr/local/cuda-13.0)
RUN case "${TORCH_TRT_VERSION}" in \
        v[0-9]*) export RELEASE=1 BUILD_VERSION="${TORCH_TRT_VERSION#v}" ;; \
    esac; \
    export TORCH_PATH="$(python3 -c 'import os, torch; print(os.path.dirname(torch.__file__))')"; \
    echo "TORCH_PATH=${TORCH_PATH}  RELEASE=${RELEASE:-0}  BUILD_VERSION=${BUILD_VERSION:-<dev0+sha>}"; \
    uv pip install pyyaml && \
    cd /tmp && \
    ( git clone --branch=${TORCH_TRT_VERSION} --depth=1 https://github.com/pytorch/TensorRT torch_tensorrt || \
      git clone --depth=1 https://github.com/pytorch/TensorRT torch_tensorrt ) && \
    cd /tmp/torch_tensorrt && \
    \
    # CUDA: /usr/local/cuda-13.0 -> /usr/local/cuda
    grep -rl 'cuda-13\.0' --include='MODULE.bazel' --include='WORKSPACE*' --include='*.bzl' . | \
      xargs -r sed -i 's|/usr/local/cuda-13.0|/usr/local/cuda|g' && \
    \
    # TensorRT: replace the tensorrt_sbsa http_archive with the local install (same archive:BUILD layout)
    perl -0pi -e 's|http_archive\(\n\s*name = "tensorrt_sbsa",.*?\n\)|new_local_repository(\n    name = "tensorrt_sbsa",\n    build_file = "@//third_party/tensorrt/archive:BUILD",\n    path = "$ENV{TRT_SHIM}",\n)|s' MODULE.bazel && \
    grep -q "path = \"${TRT_SHIM}\"" MODULE.bazel && \
    echo "== MODULE.bazel patched ==" && \
    grep -n -B1 -A4 'name = "tensorrt_sbsa"' MODULE.bazel && \
    grep -n '/usr/local/cuda' MODULE.bazel && \
    \
    # Wheel metadata: drop the PyPI `tensorrt` dependency (it pulls tensorrt-cu13-libs, a second copy of
    # libnvinfer) and the optional executorch backend (pulls ~10 heavy packages).
    sed -i '/^def get_sbsa_requirements/,/^def /{/"tensorrt>=10\.16\.1,<10\.17\.0",/d;/EXECUTORCH_REQUIREMENT,/d}' setup.py && \
    echo "== get_sbsa_requirements after patch ==" && \
    sed -n '/^def get_sbsa_requirements/,/^def get_x86_64_requirements/p' setup.py && \
    \
    python3 setup.py bdist_wheel && \
    cp dist/torch_tensorrt*.whl /opt && \
    cd / && rm -rf /tmp/torch_tensorrt /root/.cache/bazel

# Install the wheel plus Python bindings that use the already-installed libnvinfer:
#   0. bindings already importable (python3-libnvinfer linked by tensorrt:jetpack) -> nothing
#   1. the `tensorrt-*.whl` that cudastack copied out of the tarball (bindings only, no libs)
#   2. otherwise the PyPI bindings wheel, without tensorrt-cu13-libs
# Then verify no second copy of libnvinfer landed in the venv, and that libtorchtrt links the system one.
RUN uv pip install /opt/torch_tensorrt*.whl && \
    TRT_WHL="$(ls /usr/local/lib/python${PYTHON_VERSION}/dist-packages/tensorrt-10*-cp$(echo ${PYTHON_VERSION} | tr -d .)-*.whl 2>/dev/null | head -1)"; \
    if python3 -c "import tensorrt" >/dev/null 2>&1; then \
        echo "TensorRT bindings already importable (tensorrt:jetpack), nothing to install"; \
    elif [ -n "$TRT_WHL" ]; then \
        echo "Installing TensorRT bindings from tarball wheel: $TRT_WHL"; \
        uv pip install --no-deps "$TRT_WHL"; \
    else \
        echo "Tarball bindings wheel not found; installing PyPI bindings without libs"; \
        uv pip install --no-deps "tensorrt-cu13-bindings>=10.16,<10.17"; \
    fi && \
    python3 -c "import tensorrt as trt; print('tensorrt', trt.__version__, trt.__file__)" && \
    python3 -c "import torch_tensorrt; print('torch_tensorrt', torch_tensorrt.__version__)" && \
    ( ! ls -d ${VENV_DIR}/lib/python*/site-packages/tensorrt_libs >/dev/null 2>&1 || \
      { echo "ERROR: PyPI tensorrt_libs ended up in the venv (second libnvinfer copy)" >&2; exit 1; } ) && \
    ldd ${VENV_DIR}/lib/python*/site-packages/torch_tensorrt/lib/libtorchtrt.so | grep -E 'nvinfer|libtorch|libc10' && \
    python3 -c "import numpy as np, tensorrt as trt; b = trt.Builder(trt.Logger(trt.Logger.WARNING)); n = b.create_network(0); x = n.add_input('x', trt.float32, (1,3,8,8)); c = n.add_convolution_nd(x, 4, (3,3), trt.Weights(np.ones((4,3,3,3), np.float32))); n.mark_output(c.get_output(0)); p = b.build_serialized_network(n, b.create_builder_config()); assert p is not None, 'engine build failed'; print('engine build OK', len(bytes(p)), 'bytes')" && \
    uv cache clean \
    || exit 1; \
    twine upload --verbose /opt/torch_tensorrt*.whl || echo "failed to upload wheel to ${TWINE_REPOSITORY_URL}"

# torchtrtc needs libtorch at runtime; everything lives in the venv, not in dist-packages.
ENV LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:/opt/venv/lib/python${PYTHON_VERSION}/site-packages/torch/lib \
    PATH=${PATH}:/opt/venv/lib/python${PYTHON_VERSION}/site-packages/torch_tensorrt/bin
