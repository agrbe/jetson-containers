#---
# name: apache-tvm-ffi
# group: ml
# config: config.py
# depends: [python, cmake, ninja]
# buildkit_device: nvidia.com/gpu=all
# test: test.py
# notes: https://github.com/apache/tvm-ffi
#---
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG APACHE_TVM_FFI_VERSION \
    FORCE_BUILD=off \
    TMP=/tmp/apache-tvm-ffi

COPY build.sh install.sh $TMP/

RUN $TMP/install.sh || $TMP/build.sh
