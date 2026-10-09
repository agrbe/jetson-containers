#!/usr/bin/env bash
# Locate the TensorRT install (JetPack .deb layout via tensorrt:jetpack, or the cudastack
# tarball layout) and expose it in the flat include/ + lib/ layout that upstream's
# third_party/tensorrt/archive:BUILD expects. Fail fast if missing.
set -e

TRT_LIB="$(ldconfig -p | awk '/libnvinfer\.so\.10 /{print $NF; exit}')"
[ -n "$TRT_LIB" ] || TRT_LIB="$(find /usr/local/cuda/targets /usr/lib/aarch64-linux-gnu /usr/local/lib -name 'libnvinfer.so.10' 2>/dev/null | head -1)"
[ -n "$TRT_LIB" ] || { echo "ERROR: libnvinfer.so.10 not found; base image lacks TensorRT (cudastack WITH_TENSORRT=1)" >&2; exit 1; }
TRT_LIB_DIR="$(dirname "$TRT_LIB")"
TRT_INC_DIR="$(dirname "$(find /usr/include -maxdepth 2 -name NvInfer.h -print -quit 2>/dev/null)")"
[ -e "$TRT_INC_DIR/NvInfer.h" ] || { echo "ERROR: NvInfer.h not found under /usr/include; TensorRT headers missing in base image" >&2; exit 1; }
[ -e "$TRT_INC_DIR/NvInferPlugin.h" ] || { echo "ERROR: $TRT_INC_DIR/NvInferPlugin.h not found" >&2; exit 1; }

mkdir -p ${TRT_SHIM}/include ${TRT_SHIM}/lib
for h in "$TRT_INC_DIR"/Nv*.h; do ln -sf "$h" ${TRT_SHIM}/include/; done
for l in "$TRT_LIB_DIR"/libnv*.so*; do ln -sf "$l" ${TRT_SHIM}/lib/; done
for base in libnvinfer libnvinfer_plugin libnvonnxparser; do
    [ -e ${TRT_SHIM}/lib/${base}.so ] || { [ -e "$TRT_LIB_DIR/${base}.so.10" ] && ln -s "$TRT_LIB_DIR/${base}.so.10" ${TRT_SHIM}/lib/${base}.so; } || true
done
[ -e ${TRT_SHIM}/lib/libnvinfer.so ] && [ -e ${TRT_SHIM}/lib/libnvinfer_plugin.so ] || { echo "ERROR: could not create libnvinfer.so / libnvinfer_plugin.so links in ${TRT_SHIM}/lib" >&2; exit 1; }

# libnvinfer dlopen()s libnvinfer_builder_resource_smXX.so.<version> by file name. Their SONAME is
# "do_not_link_against_*", so ld.so.cache cannot resolve them, and the tarball dir is not on
# LD_LIBRARY_PATH nor a default loader dir -> engine builds fail on Orin (sm86 family). Default
# loader dirs are searched by file name, so link the resources there.
if [ "$TRT_LIB_DIR" != /usr/lib/aarch64-linux-gnu ]; then
    for r in "$TRT_LIB_DIR"/libnvinfer_builder_resource*.so*; do [ -e "$r" ] && ln -sfn "$r" /usr/lib/aarch64-linux-gnu/; done
    ldconfig
fi
ls /usr/lib/aarch64-linux-gnu/libnvinfer_builder_resource_sm86* >/dev/null 2>&1 || { echo "ERROR: libnvinfer_builder_resource_sm86 not reachable by the loader" >&2; exit 1; }

echo "TensorRT libs : $TRT_LIB_DIR"
echo "TensorRT hdrs : $TRT_INC_DIR"
echo "TensorRT ver  : $(grep -h 'define NV_TENSORRT_\(MAJOR\|MINOR\|PATCH\|BUILD\)' "$TRT_INC_DIR/NvInferVersion.h" | awk '{print $3}' | paste -sd.)"
ls -l ${TRT_SHIM}/lib/libnvinfer.so ${TRT_SHIM}/lib/libnvinfer_plugin.so
