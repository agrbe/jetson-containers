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

ARG FORCE_BUILD=off

COPY trt_shim.sh install.sh build.sh /tmp/torch_tensorrt/

# Expose the system TensorRT in the layout the bazel build and the loader expect
RUN /tmp/torch_tensorrt/trt_shim.sh

RUN /tmp/torch_tensorrt/install.sh || /tmp/torch_tensorrt/build.sh

# torchtrtc needs libtorch at runtime; everything lives in the venv, not in dist-packages.
ENV LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:/opt/venv/lib/python${PYTHON_VERSION}/site-packages/torch/lib \
    PATH=${PATH}:/opt/venv/lib/python${PYTHON_VERSION}/site-packages/torch_tensorrt/bin
