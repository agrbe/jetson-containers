#!/usr/bin/env python3
# Fails if any TensorRT-Edge-LLM artifact (wheel native payload, python CLIs, C++ examples,
# TRT plugin, CuTe DSL sm_87 kernels) is missing or broken.
import os, shutil, subprocess, sys
print('testing tensorrt_edgellm...')

import tensorrt_edgellm
print('tensorrt_edgellm version:', tensorrt_edgellm.__version__)
if len(sys.argv) > 1:
    assert tensorrt_edgellm.__version__ == sys.argv[1], f'expected {sys.argv[1]}, got {tensorrt_edgellm.__version__}'

src = os.environ.get('TENSORRT_EDGELLM_DIR', '/opt/TensorRT-Edge-LLM')

def run_help(cmd):
    exe = shutil.which(cmd)
    assert exe, f'{cmd} not found in PATH'
    r = subprocess.run([exe, '--help'], capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, f'{cmd} --help failed ({r.returncode}):\n{r.stdout[-2000:]}{r.stderr[-2000:]}'
    print(f'  {cmd} --help OK')

# Python CLIs (pyproject [project.scripts])
for c in ['build', 'export', 'quantize', 'insert-lora', 'merge-lora', 'process-lora', 'reduce-vocab', 'serve']:
    run_help(f'tensorrt-edgellm-{c}')

# C++ runtime examples (Dockerfile puts build/examples/{llm,multimodal} on PATH)
for c in ['llm_build', 'llm_inference', 'llm_bench', 'llm_stream',
          'visual_build', 'audio_build', 'action_build', 'action_inference']:
    run_help(c)

# CuTe DSL kernels compiled for this GPU arch
cutedsl = os.path.join(src, 'cpp/kernels/cuteDSLArtifact/aarch64/sm_87/libcutedsl_aarch64.a')
assert os.path.getsize(cutedsl) > 0, f'missing {cutedsl}'
print('  CuTe DSL sm_87 kernels OK')

# Wheel native payload: _native/variants.json selects this device's pybind runtime + plugin
from tensorrt_edgellm import runtime
rt = runtime.load()
assert hasattr(rt, 'LLMRuntime') and hasattr(rt, 'LLMBuilder'), 'pybind runtime missing LLMRuntime/LLMBuilder'
print(f'  runtime.load() OK ({rt.__file__})')

# load() dlopens the payload's TensorRT plugin, which registers its creators
import tensorrt as trt
plugins = {c.name for c in trt.get_plugin_registry().all_creators}
missing = {'AttentionPlugin', 'RmsNormPlugin', 'Int4GroupwiseGemmPluginV2', 'ViTAttentionPlugin'} - plugins
assert not missing, f'edgellm TRT plugins not registered: {missing}'
print(f'  TensorRT {trt.__version__} plugin OK ({len(plugins)} creators, {os.environ["EDGELLM_PLUGIN_PATH"]})')

print('\ntensorrt_edgellm OK\n')
