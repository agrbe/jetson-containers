#!/usr/bin/env bash
set -ex

echo "Building apache-tvm-ffi ${APACHE_TVM_FFI_VERSION}"

REPO_URL="https://github.com/apache/tvm-ffi"
REPO_DIR="/opt/tvm-ffi"

# setuptools-scm takes the wheel version from the checked-out tag
git clone --recursive --depth=1 --branch=v${APACHE_TVM_FFI_VERSION} $REPO_URL $REPO_DIR

# scikit-build-core backend (CMake + Cython), build deps come from build isolation
cd $REPO_DIR
uv build --wheel -v --out-dir $REPO_DIR/wheels .
uv pip install $REPO_DIR/wheels/apache_tvm_ffi-*.whl

twine upload --verbose $REPO_DIR/wheels/apache_tvm_ffi-*.whl || echo "failed to upload wheel to ${TWINE_REPOSITORY_URL}"
