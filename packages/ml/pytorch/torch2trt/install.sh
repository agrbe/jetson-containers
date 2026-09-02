#!/usr/bin/env bash
# =============================================================================
# install.sh — torch2trt (jetson-containers package)
# Builds and installs torch2trt with its C++ plugins inside the container.
#
# Goals:
# - Use the TensorRT already installed by cudastack (tarball layout), wherever it is.
# - Install Python bindings that match the running interpreter, without pulling
#   tensorrt-cu13-libs from PyPI (that would add a second copy of libnvinfer).
# - Fail before cloning or compiling when a requirement is missing.
#
# Usage:
#   bash /tmp/torch2trt/install.sh
#
# Optional variables:
#   TORCH2TRT_REPO_URL=https://github.com/NVIDIA-AI-IOT/torch2trt
#   TORCH2TRT_REF=            -> branch/tag; empty = default branch
#   SOURCE_DIR=/opt/torch2trt -> kept after install (test.py imports from the package)
#   CUDA_ARCHITECTURES=87     -> from the cuda base image ENV; CMake plugin targets
#   TRT_PATCH_DIR=/tmp/torch2trt -> jetson-containers patches (flattener.py)
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
# --- Source checkout information --------------------------------------------
TORCH2TRT_REPO_URL="${TORCH2TRT_REPO_URL:-https://github.com/NVIDIA-AI-IOT/torch2trt}"
TORCH2TRT_REF="${TORCH2TRT_REF:-}"
SOURCE_DIR="${SOURCE_DIR:-/opt/torch2trt}"
TRT_PATCH_DIR="${TRT_PATCH_DIR:-/tmp/torch2trt}"

# --- Build information -------------------------------------------------------
CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-}"
NPROC="${NPROC:-$(nproc)}"

# --- Resolved at runtime -----------------------------------------------------
PY_TAG=""
TRT_INC_DIR=""
TRT_LIB_DIR=""
# ──────────────────────────────────────────────────────────────────────────────

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

require_command() {
    local cmd="$1"

    # Checking tools upfront keeps failures clear and avoids wasting build time.
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Required command not found: $cmd"
        exit 1
    fi
}

log_step() {
    local step="$1"
    local message="$2"

    echo ""
    echo "-----------------------------------------------------------------------------"
    echo "[$step] $message"
    echo "-----------------------------------------------------------------------------"
}

print_config() {
    echo "════════════════════════════════════════════════════════════════════════════"
    echo "  torch2trt build"
    echo "════════════════════════════════════════════════════════════════════════════"
    echo "  TORCH2TRT_REPO_URL : $TORCH2TRT_REPO_URL"
    echo "  TORCH2TRT_REF      : ${TORCH2TRT_REF:-<default branch>}"
    echo "  SOURCE_DIR         : $SOURCE_DIR"
    echo "  PY_TAG             : $PY_TAG"
    echo "  TRT_INC_DIR        : $TRT_INC_DIR"
    echo "  TRT_LIB_DIR        : $TRT_LIB_DIR"
    echo "  CUDA_ARCHITECTURES : $CUDA_ARCHITECTURES"
    echo "  Jobs               : $NPROC"
    echo "════════════════════════════════════════════════════════════════════════════"
    echo ""
}

# -----------------------------------------------------------------------------
# Requirement checks
# -----------------------------------------------------------------------------

validate_system_requirements() {
    echo "🔎 Checking system requirements..."

    require_command git
    require_command python3
    require_command uv
    require_command cmake
    require_command nvcc

    # Empty CUDA_ARCHITECTURES makes CMake's set_property fail late; fail here instead.
    if [ -z "$CUDA_ARCHITECTURES" ]; then
        echo "❌ CUDA_ARCHITECTURES is empty (expected from the cuda base image, e.g. 87)"
        exit 1
    fi

    echo "✅ System requirements verified."
    echo ""
}

resolve_python_tag() {
    # The tarball ships one bindings wheel per interpreter (cp310..cp313); pick ours.
    PY_TAG="$(python3 -c 'import sys; print(f"cp{sys.version_info.major}{sys.version_info.minor}")')"
}

resolve_tensorrt_paths() {
    local header lib

    # cudastack installs the tarball with headers flat in /usr/include and libs in
    # /usr/local/cuda/targets/aarch64-linux/lib (Tegra) or /usr/lib/aarch64-linux-gnu (SBSA).
    # torch2trt's setup.py hardcodes the JetPack .deb layout, so both are resolved here.
    header="$(find /usr/include /usr/local/include /opt/tensorrt/include -maxdepth 2 -name NvInfer.h -print -quit 2>/dev/null || true)"
    if [ -z "$header" ]; then
        echo "❌ NvInfer.h not found; TensorRT headers missing in the base image"
        exit 1
    fi
    TRT_INC_DIR="$(dirname "$header")"

    # ldconfig knows the tarball lib dir because install_tensorrt.sh registered it.
    lib="$(ldconfig -p | awk '/libnvinfer\.so\.10 /{print $NF; exit}')"
    if [ -z "$lib" ]; then
        lib="$(find /usr/local/cuda/targets /usr/lib/aarch64-linux-gnu /usr/local/lib -name 'libnvinfer.so.10' -print -quit 2>/dev/null || true)"
    fi
    if [ -z "$lib" ]; then
        echo "❌ libnvinfer.so.10 not found; base image lacks TensorRT (cudastack WITH_TENSORRT=1)"
        exit 1
    fi
    TRT_LIB_DIR="$(dirname "$lib")"

    # The linker needs the unversioned name for -lnvinfer.
    if [ ! -e "$TRT_LIB_DIR/libnvinfer.so" ]; then
        ln -s "$TRT_LIB_DIR/libnvinfer.so.10" "$TRT_LIB_DIR/libnvinfer.so"
    fi
}

# -----------------------------------------------------------------------------
# Build stages
# -----------------------------------------------------------------------------

expose_builder_resources() {
    # libnvinfer dlopen()s libnvinfer_builder_resource_smXX.so.<full version> by
    # file name. ld.so.cache only indexes SONAMEs, so a lib dir that is reachable
    # solely through /etc/ld.so.conf.d (the cudastack tarball layout under
    # /usr/local/cuda/targets/aarch64-linux/lib) resolves libnvinfer.so.10 but not
    # the per-SM resources: "Unable to load library: libnvinfer_builder_resource_sm86".
    # Default loader dirs are searched by file name, so link the resources there.
    local trusted_dir=/usr/lib/aarch64-linux-gnu
    local f

    if [ "$TRT_LIB_DIR" = "$trusted_dir" ]; then
        echo "TensorRT already in $trusted_dir; nothing to link"
        return 0
    fi

    shopt -s nullglob
    for f in "$TRT_LIB_DIR"/libnvinfer_builder_resource*.so*; do
        ln -sfn "$f" "$trusted_dir/$(basename "$f")"
        echo "linked $(basename "$f")"
    done
    shopt -u nullglob
    ldconfig
}

install_tensorrt_bindings() {
    local wheel

    # torch2trt's setup.py does `import tensorrt` at import time, so bindings must
    # exist in the venv before the build. Prefer whatever a previous stage installed.
    if python3 -c "import tensorrt" >/dev/null 2>&1; then
        echo "TensorRT bindings already importable: $(python3 -c 'import tensorrt as t; print(t.__version__, t.__file__)')"
        return 0
    fi

    # cudastack copies the tarball's python/*.whl into dist-packages without installing them.
    wheel="$(find /usr -name "tensorrt-10*-${PY_TAG}-*-linux_aarch64.whl" -print -quit 2>/dev/null || true)"
    if [ -n "$wheel" ]; then
        echo "Installing TensorRT bindings from tarball wheel: $wheel"
        uv pip install --no-deps "$wheel"
    else
        # Bindings only: tensorrt-cu13-libs would add a second libnvinfer copy to the venv.
        echo "Tarball bindings wheel for ${PY_TAG} not found; installing PyPI bindings without libs"
        uv pip install --no-deps "tensorrt-cu13-bindings>=10.16,<10.17"
    fi

    python3 -c "import tensorrt as t; print('tensorrt', t.__version__, t.__file__)"
}

prepare_checkout() {
    local clone_args=(--depth=1)

    if [ -n "$TORCH2TRT_REF" ]; then
        clone_args+=(--branch="$TORCH2TRT_REF")
    fi

    rm -rf "$SOURCE_DIR"
    git clone "${clone_args[@]}" "$TORCH2TRT_REPO_URL" "$SOURCE_DIR"

    # jetson-containers patch: flattener.py replaces the upstream module.
    cp "$TRT_PATCH_DIR/flattener.py" "$SOURCE_DIR/torch2trt/"
}

patch_sources() {
    (
        cd "$SOURCE_DIR"

        # Point setup.py at the real TensorRT location instead of the JetPack .deb paths.
        sed -i "s|return \"/usr/include/aarch64-linux-gnu\"|return \"${TRT_INC_DIR}\"|" setup.py
        sed -i "s|return \"/usr/lib/aarch64-linux-gnu\"|return \"${TRT_LIB_DIR}\"|" setup.py
        grep -n "return \"${TRT_INC_DIR}\"\|return \"${TRT_LIB_DIR}\"" setup.py

        # CMake: architectures come from -D (see build_plugins); Catch2 tests are not needed.
        sed -i 's|^set(CUDA_ARCHITECTURES.*|#|g' CMakeLists.txt
        sed -i 's|Catch2_FOUND|False|g' CMakeLists.txt
    )
}

build_python_package() {
    (
        cd "$SOURCE_DIR"

        # `--plugins` is consumed by setup.py before setup(); bdist_wheel keeps the venv
        # install path uniform with the rest of the chain and survives setuptools>=80.
        python3 setup.py bdist_wheel --plugins
        uv pip install --no-deps dist/torch2trt-*.whl
    )
}

build_plugins() {
    (
        cd "$SOURCE_DIR"

        # -I/-L are passed through because the tarball layout is not on the default
        # compiler search paths (only ldconfig knows the lib dir at runtime).
        cmake -B build \
            -DCUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
            -DCMAKE_CXX_FLAGS="-I${TRT_INC_DIR}" \
            -DCMAKE_CUDA_FLAGS="-I${TRT_INC_DIR}" \
            -DCMAKE_SHARED_LINKER_FLAGS="-L${TRT_LIB_DIR}" \
            -DCMAKE_EXE_LINKER_FLAGS="-L${TRT_LIB_DIR}" \
            .
        cmake --build build --target install -j "$NPROC"
        ldconfig
    )
}

install_extras() {
    uv pip install --no-build-isolation onnx-graphsurgeon
}

cleanup_build_artifacts() {
    # Sources stay in SOURCE_DIR for test.py; only build products and caches go.
    rm -rf "$SOURCE_DIR/build" "$SOURCE_DIR/dist" "$SOURCE_DIR"/*.egg-info
    uv cache clean
}

# -----------------------------------------------------------------------------
# Smoke test
# -----------------------------------------------------------------------------

smoke_test() {
    log_step "TEST" "Import check + engine build"
    python3 -c "
import tensorrt, torch, torch2trt
print('tensorrt ', tensorrt.__version__)
print('torch    ', torch.__version__)
print('torch2trt', torch2trt.__file__)
"
    ldconfig -p | grep -E 'torch2trt_plugins|libnvinfer\.so\.10'

    # Building an engine is the only check that exercises the per-SM builder
    # resources; import alone passes even when engine builds are broken.
    python3 -c "
import numpy as np, tensorrt as trt
b = trt.Builder(trt.Logger(trt.Logger.WARNING)); n = b.create_network(0)
x = n.add_input('x', trt.float32, (1, 3, 8, 8))
c = n.add_convolution_nd(x, 4, (3, 3), trt.Weights(np.ones((4, 3, 3, 3), np.float32)))
n.mark_output(c.get_output(0))
plan = b.build_serialized_network(n, b.create_builder_config())
assert plan is not None, 'engine build failed (builder resource not loadable?)'
print('engine build OK:', len(bytes(plan)), 'bytes')
"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    validate_system_requirements
    resolve_python_tag
    resolve_tensorrt_paths
    print_config

    log_step "1/7" "Exposing TensorRT builder resources to the loader"
    expose_builder_resources

    log_step "2/7" "TensorRT Python bindings"
    install_tensorrt_bindings

    log_step "3/7" "Checkout"
    prepare_checkout
    patch_sources

    log_step "4/7" "Python package (with plugins extension)"
    build_python_package

    log_step "5/7" "CMake plugins library"
    build_plugins

    log_step "6/7" "Extras"
    install_extras

    log_step "7/7" "Cleanup"
    cleanup_build_artifacts

    smoke_test
}

main "$@"
