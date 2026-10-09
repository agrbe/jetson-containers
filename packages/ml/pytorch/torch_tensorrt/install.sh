#!/usr/bin/env bash
# Install torch_tensorrt from the pip index, or from a local wheel when called by build.sh:
#   install.sh [/path/to/torch_tensorrt.whl]
# then install the TensorRT Python bindings that use the already-installed libnvinfer:
#   0. bindings already importable (python3-libnvinfer linked by tensorrt:jetpack) -> nothing
#   1. the `tensorrt-*.whl` that cudastack copied out of the tarball (bindings only, no libs)
#   2. otherwise the PyPI bindings wheel, without tensorrt-cu13-libs
# and verify no second copy of libnvinfer landed in the venv, and that libtorchtrt links the system one.
set -ex

WHEEL="$1"

if [ -z "$WHEEL" ]; then
    if [ "$FORCE_BUILD" == "on" ]; then
        echo "Forcing build of torch_tensorrt ${TORCH_TRT_VERSION}"
        exit 1
    fi
    case "${TORCH_TRT_VERSION}" in
        v[0-9]*) ;;
        *) echo "No release wheel for torch_tensorrt ${TORCH_TRT_VERSION}"; exit 1 ;;
    esac
    WHEEL="torch-tensorrt==${TORCH_TRT_VERSION#v}"
fi

# the locally built wheel already drops the PyPI `tensorrt` dependency (second libnvinfer copy)
uv pip install "$WHEEL"

TRT_WHL="$(ls /usr/local/lib/python${PYTHON_VERSION}/dist-packages/tensorrt-10*-cp$(echo ${PYTHON_VERSION} | tr -d .)-*.whl 2>/dev/null | head -1)"
if python3 -c "import tensorrt" >/dev/null 2>&1; then
    echo "TensorRT bindings already importable (tensorrt:jetpack), nothing to install"
elif [ -n "$TRT_WHL" ]; then
    echo "Installing TensorRT bindings from tarball wheel: $TRT_WHL"
    uv pip install --no-deps "$TRT_WHL"
else
    echo "Tarball bindings wheel not found; installing PyPI bindings without libs"
    uv pip install --no-deps "tensorrt-cu13-bindings>=10.16,<10.17"
fi

python3 -c "import tensorrt as trt; print('tensorrt', trt.__version__, trt.__file__)"
python3 -c "import torch_tensorrt; print('torch_tensorrt', torch_tensorrt.__version__)"

if ls -d ${VENV_DIR}/lib/python*/site-packages/tensorrt_libs >/dev/null 2>&1; then
    echo "ERROR: PyPI tensorrt_libs ended up in the venv (second libnvinfer copy)" >&2
    exit 1
fi

ldd ${VENV_DIR}/lib/python*/site-packages/torch_tensorrt/lib/libtorchtrt.so | grep -E 'nvinfer|libtorch|libc10'

python3 -c "import numpy as np, tensorrt as trt; b = trt.Builder(trt.Logger(trt.Logger.WARNING)); n = b.create_network(0); x = n.add_input('x', trt.float32, (1,3,8,8)); c = n.add_convolution_nd(x, 4, (3,3), trt.Weights(np.ones((4,3,3,3), np.float32))); n.mark_output(c.get_output(0)); p = b.build_serialized_network(n, b.create_builder_config()); assert p is not None, 'engine build failed'; print('engine build OK', len(bytes(p)), 'bytes')"

uv cache clean
