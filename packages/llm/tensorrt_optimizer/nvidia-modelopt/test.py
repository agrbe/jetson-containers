#!/usr/bin/env python3
# Smoke test: modelopt imports, version, INT8 PTQ on CUDA, CUDA extension builds.
import sys, time
print('testing TensorRT-Model-Optimizer...')

import torch
import modelopt
import modelopt.torch.quantization as mtq
from modelopt.torch.quantization.extensions import get_cuda_ext

print('modelopt version:', modelopt.__version__)
if len(sys.argv) > 1:
    assert modelopt.__version__ == sys.argv[1], f'expected modelopt {sys.argv[1]}, got {modelopt.__version__}'

assert torch.cuda.is_available(), 'CUDA not available'
print('device:', torch.cuda.get_device_name(), torch.cuda.get_device_capability())

# INT8 W8A8 (FP8/NVFP4 need sm_89+/sm_100+; Orin is sm_87)
torch.manual_seed(0)
model = torch.nn.Sequential(torch.nn.Linear(64, 64), torch.nn.ReLU(), torch.nn.Linear(64, 16)).cuda()
data = [torch.randn(8, 64, device='cuda') for _ in range(4)]
ref = model(data[0])

def forward_loop(m):
    for x in data:
        m(x)

model = mtq.quantize(model, mtq.INT8_DEFAULT_CFG, forward_loop)
n_quant = sum(1 for _, m in model.named_modules() if m.__class__.__name__ == 'TensorQuantizer' and m.is_enabled)
assert n_quant >= 4, f'expected >=4 enabled quantizers, got {n_quant}'
assert model[0].weight_quantizer.amax is not None, 'weight quantizer not calibrated'
assert model[0].input_quantizer.amax is not None, 'input quantizer not calibrated'

out = model(data[0])
err = (out - ref).abs().max().item()
print(f'int8 quantizers={n_quant}  max|q-ref|={err:.4f}')
assert torch.isfinite(out).all() and 0 < err < 0.1, f'unexpected int8 error {err}'

# CUDA fake-quant extension (JIT-compiled with nvcc on first use)
t = time.time()
ext = get_cuda_ext(raise_if_failed=True)
x = torch.randn(1024, device='cuda')
amax = x.abs().max()
y = ext.fake_tensor_quant(x, amax, 8, False, False)
assert torch.isfinite(y).all() and (y - x).abs().max() <= amax / 127 + 1e-6, 'cuda ext fake quant wrong'
print(f'cuda ext {ext.__name__} OK ({time.time() - t:.1f}s)')

print('TensorRT-Model-Optimizer OK\n')
