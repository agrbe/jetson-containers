#---
# name: torch2trt
# group: pytorch
# config: config.py
# depends: [cudastack:standard, pytorch, torchvision]
# buildkit_device: nvidia.com/gpu=all
# test: test.py
#---
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG TORCH2TRT_REF \
    TORCH2TRT_SHA

COPY install.sh patches/ /tmp/torch2trt/
RUN bash /tmp/torch2trt/install.sh
