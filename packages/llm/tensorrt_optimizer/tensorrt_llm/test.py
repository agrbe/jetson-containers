import tensorrt_llm
import subprocess

print('tensorrt_llm version:', tensorrt_llm.__version__)

subprocess.run('trtllm-build --help > /dev/null && echo "trtllm-build OK"', shell=True, check=True)
