# CuTe DSL (nvidia-cutlass-dsl) shared by cutlass, tensorrt_edgellm and vllm.
# TensorRT-Edge-LLM 0.10.1 accepts exactly 4.7.0 (build_cutedsl.py checks it);
# vllm 0.31.0 asks for 4.7.1 only for FA4 (sm100), so vllm/build.sh relaxes it.
CUTLASS_DSL_VERSION = '4.7.0'
