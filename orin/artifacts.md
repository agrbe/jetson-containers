# Compiled Artifacts — Jetson AGX Orin / JetPack 7.2

Source: branch `jetson-orin` @ `b966a3b1`

Binaries are **not** tracked in this repository. This file records what was built,
under which toolchain, and how to reproduce it. The artifacts themselves live in
the local devpi/APT servers and in the backup directory listed at the bottom.

## Build environment

Read from the produced image, not from the pins in `orin/build.sh` — these are the
versions that actually went into the artifacts.

| Component | Version |
|---|---|
| L4T / JetPack | 39.2 / 7.2 |
| Ubuntu | 24.04 |
| Python | 3.12.14 |
| CUDA (nvcc) | 13.2 |
| cuDNN | 9.21.1 (`92101`) |
| `torch.cuda.get_arch_list()` | `['sm_87']` |

TensorRT is absent on purpose: the `pytorch` dependency chain does not pull it in,
so the `TENSORRT_VERSION=10.16.2` pin in `orin/build.sh` was not exercised by this
build and is not part of these artifacts.

## Wheels

| File | Version | Size | SHA256 |
|---|---|---|---|
| `onnxruntime_gpu-1.27.1-cp312-cp312-linux_aarch64.whl` | 1.27.1 | 56 MB | `4b02e8ea1f1b65a8b3ecbffc5434c27ce88f80ec231b0c5d67a6efdd75f26002` |
| `torch-2.12.0-cp312-cp312-linux_aarch64.whl` | 2.12.0 | 218 MB | `ca080957b7d99a6b5a4ed8f2dd3bacb95922b99c0e41d3c24733cc5088189fe1` |

`torch` was compiled from source and carries 409 `sm_87` kernels in
`libtorch_cuda.so`. The 6 `sm_100` kernels also present come from NVIDIA libraries
linked into the build, not from `TORCH_CUDA_ARCH_LIST`.

`onnxruntime_gpu` exposes `TensorrtExecutionProvider`, `CUDAExecutionProvider` and
`CPUExecutionProvider`.

## Tarballs (`tarpack`)

Each tarball ships with a `.sha256` sidecar; `tarpack install` downloads both
(`packages/build/build-essential/tarpack:15-16`), so publish them together.

| File | Version | Size | SHA256 |
|---|---|---|---|
| `onnxruntime-gpu-1.27.1.tar.gz` | 1.27.1 | 46 MB | `78977f89a6f2293055e323ca9e9a773b084f767218051d4aa1581570ded8628b` |
| `gdrcopy-2.5.2.tar.gz` | 2.5.2 | 366 KB | `dd8140364f4db334ffb5d3bc3a866c4e5858d66ddd0f06f9cd95faf0eea58253` |

The onnxruntime tarball is the C++ development package: headers under
`include/onnxruntime/`, shared objects under `lib/`, plus `lib/cmake/onnxruntime/`
and `lib/pkgconfig/libonnxruntime.pc`.

## Reproducing

```bash
jetson-containers build onnxruntime:1.27.1-builder
jetson-containers build pytorch:2.12-builder
```

The `-builder` variants set `FORCE_BUILD=on`, which makes `install.sh` exit
non-zero so the `install.sh || build.sh` line in each Dockerfile falls through to a
source build. Both upload their wheel via twine and their tarball via `tarpack`
when the build finishes (`packages/ml/pytorch/build.sh:122`,
`packages/ml/onnxruntime/build.sh:147-148`).

Those uploads end in `|| echo "failed to upload ..."`, so a publishing failure does
not fail the build. Check afterwards:

```bash
grep -c "failed to upload" logs/*/build/*.txt
```

## Local patches affecting these artifacts

| File | Effect |
|---|---|
| `jetson_containers/l4t_version.py:331` | restricts JetPack 7 to `sm_87` (upstream builds `[87, 110, 120, 121]`) |
| `packages/cuda/cuda/install.sh:50-76` | rewrites the `cuda::proclaims_copyable_arguments` specializations in the CUDA 13.2 CCCL headers, which GCC 13.3 rejects |
| `packages/ml/onnxruntime/config.py:40` | adds onnxruntime 1.27.1 (`>=cu132`, branch `rel-1.27.1`) |
| `packages/net/devpi/model.patch:21-24` | fixes the devpi mirror blacklist: entries were compared with a trailing newline and were never normalized, so every listed package still resolved from pypi.org |
| `packages/net/devpi/blacklist.txt` | `spas_sage_attn` → `spas-sage-attn`, `mamba` → `mamba-ssm`, dropped the `awq_inference_engine` duplicate |

## Serving and backup

Local servers, started by `./launch_pypi.sh`:

| Store | URL | Backing directory |
|---|---|---|
| devpi (wheels) | `http://localhost:3141/jp7/cu132/+simple/` | `packages/net/devpi/cache/devpi/` |
| nginx/WebDAV (tarballs) | `http://localhost:8034/jp7/cu132/24.04/` | `packages/net/devpi/cache/apt/` |

The index path `jp7/cu132` and the APT path `jp7/cu132/24.04` are derived in
`packages/cuda/cuda/config.py:140-148` from the L4T, CUDA and `LSB_RELEASE` values.
Note that `launch_pypi.sh` creates `jp7/cu132` without the `24.04` suffix, so that
directory has to be created once by hand.

Backup copy, at `$DIST_DIR` — a relative value is resolved against the repository
root, so the default lands inside the clone:

```
dist/
├── MANIFEST.sha256      tracked
├── wheel/               gitignored
└── tarball/             gitignored
```

Only the manifest is versioned; the binaries are excluded by `.gitignore`, both
because GitHub rejects files over 100 MB (the torch wheel is 218 MB) and because
they are reproducible from the commands above.

Verify with `sha256sum --check MANIFEST.sha256` from inside `dist/`.
