#!/usr/bin/env bash
set -ex

uv pip install pre-commit nanobind #==2.5.0
# Clone the repository if it doesn't exist
git clone --branch=${VLLM_BRANCH} --recursive --depth=1 https://github.com/vllm-project/vllm /opt/vllm ||
git clone --recursive --depth=1 https://github.com/vllm-project/vllm /opt/vllm

cd /opt/vllm
env

python3 /tmp/vllm/generate_diff.py
git apply /tmp/vllm/patch.diff

sed -i \
  -e 's|^gguf.*|gguf|g' \
  -e 's|^opencv-python-headless.*||g' \
  -e 's|^mistral_common.*|mistral_common|g' \
  -e 's|^xgrammar.*|xgrammar|g' \
  requirements/common.txt

sed -i -E 's|^setuptools([<>=!~ ;].*)?$|setuptools|' requirements/common.txt

# Loosen flashinfer requirement to allow latest version.
sed -E -i 's/^(flashinfer-(python|cubin))==.*$/\1/' requirements/cuda.txt
# Same CuTe DSL as tensorrt_edgellm (vllm only needs it for FA4 on sm100)
sed -E -i "s/^(nvidia-cutlass-dsl(\[cu13\])?)==.*$/\1==${CUTLASS_DSL_VERSION}/" requirements/cuda.txt

# grep gguf requirements/common.txt


export USE_CUDNN=1
export VERBOSE=1
export CUDA_HOME=/usr/local/cuda
export PATH="${CUDA_HOME}/bin:$PATH"
export SETUPTOOLS_SCM_PRETEND_VERSION="${VLLM_VERSION}"
export DG_JIT_USE_NVRTC=1 # DeepGEMM now supports NVRTC with up to 10x compilation speedup

python3 use_existing_torch.py || python3 tools/use_existing_torch.py || echo "skipping vllm/use_existing_torch.py"

if [ -f requirements/build/cuda.txt ]; then
  BUILD_REQUIREMENTS_FILE="requirements/build/cuda.txt"
  sed -i -E 's|^setuptools([<>=!~ ;].*)?$|setuptools|' $BUILD_REQUIREMENTS_FILE
elif [ -f requirements/build.txt ]; then
  BUILD_REQUIREMENTS_FILE="requirements/build.txt"
else
  echo "Error: could not find a supported vLLM build requirements file. Expected requirements/build/cuda.txt or requirements/build.txt." >&2
  exit 1
fi

uv pip freeze > /tmp/vllm/constraints.txt
uv pip install -r "${BUILD_REQUIREMENTS_FILE}" -c /tmp/vllm/constraints.txt -v
python3 -m setuptools_scm

ARCH=$(uname -i)
if [ "${ARCH}" = "aarch64" ]; then
      export NVCC_THREADS=1
      export CUDA_NVCC_FLAGS="-Xcudafe --threads=1"
      export MAKEFLAGS='-j2'
      export CMAKE_BUILD_PARALLEL_LEVEL=$MAX_JOBS
      export NINJAFLAGS='-j2'
fi

uv build --wheel --no-build-isolation -v --out-dir /opt/vllm/wheels .
uv pip install /opt/vllm/wheels/vllm*.whl

# Optionally upload to a repository using Twine
twine upload --verbose /opt/vllm/wheels/vllm*.whl || echo "Failed to upload wheel to ${TWINE_REPOSITORY_URL}"
