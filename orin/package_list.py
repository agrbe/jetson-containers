"""Package list helpers shared by lint.py, audit.py and dep_graph.py.

Reads the package pins from packages.txt, extra pip pins from a
requirements-style file, and maps jetson-containers package names to the
pip distributions they install.
"""

import contextlib
import io
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def repo_root():
    """jetson-containers checkout: $JC_REPO, else the nearest parent holding jetson_containers/."""
    if os.environ.get('JC_REPO'):
        return Path(os.environ['JC_REPO']).expanduser().resolve()
    for d in HERE.parents:
        if (d / 'jetson_containers').is_dir():
            return d
    raise SystemExit(f"jetson-containers repo not found above {HERE}; set JC_REPO")


ROOT = repo_root()


def use_venv():
    """Re-exec under the repo venv when started elsewhere (jetson_containers needs
    its deps) and make jetson_containers importable."""
    venv = ROOT / 'venv'
    if (venv / 'bin' / 'python3').exists() and Path(sys.prefix).resolve() != venv.resolve():
        os.execv(str(venv / 'bin' / 'python3'), [str(venv / 'bin' / 'python3'), *sys.argv])
    sys.path.insert(1, str(ROOT))


def find_packages(names):
    """{name: resolved package config} via jetson_containers (after use_venv), quietly."""
    with contextlib.redirect_stdout(io.StringIO()):
        from jetson_containers.packages import find_package

        return {name: find_package(name) for name in names}

# jetson-containers package -> pip distribution(s) it installs. Packages that
# install no wheel (cuda, cudastack, llvm, ffmpeg...) map to nothing.
DISTS = {
    'pytorch': ['torch'],
    'flash-attention': ['flash-attn'],
    'flashinfer': ['flashinfer-python'],
    'onnxruntime': ['onnxruntime-gpu'],
    'cutlass': ['nvidia-cutlass'],
    'mistral_common': ['mistral-common'],
    'mooncake': ['mooncake-transfer-engine'],
    'opencv': ['opencv-contrib-python', 'opencv-contrib-python-rolling'],
    'torch_tensorrt': ['torch-tensorrt'],
    'tensorrt_llm': ['tensorrt-llm'],
    'tensorrt_edgellm': ['tensorrt-edgellm'],
    'nvidia_modelopt': ['nvidia-modelopt'],
    'causalconv1d': ['causal-conv1d'],
    'mamba': ['mamba-ssm'],
    'cudnn_frontend': ['nvidia-cudnn-frontend'],
    'pyav': ['av'],
    'cuda': [],
    'cudastack': [],
    'llvm': [],
    'ffmpeg': [],
}


def norm(name):
    """PEP 503 normalized distribution name."""
    return re.sub(r'[-_.]+', '-', name).lower()


def dists_for(package):
    base = package.split(':')[0]
    return [norm(d) for d in DISTS.get(base, [base])]


def read_packages(path):
    """Entries of a package list (one per line, '#' comments), like build_image.sh reads it."""
    lines = (line.split('#')[0].strip() for line in Path(path).read_text().splitlines())
    return [line for line in lines if line]


def load_env(path):
    """Export KEY=VALUE lines of a .env file, like 'set -a; source .env'."""
    if not path or not Path(path).is_file():
        return
    for line in Path(path).read_text().splitlines():
        m = re.match(r'\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)', line)
        if m and not line.lstrip().startswith('#'):
            value = m.group(2).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
                value = value[1:-1]
            os.environ.setdefault(m.group(1), value)


def read_pip_pins(path):
    """{dist: version} from a requirements-style file of 'name==version' lines."""
    pins = {}
    if path:
        for line in Path(path).read_text().splitlines():
            m = re.match(r'\s*([A-Za-z0-9_.\-]+)\s*==\s*([^\s;#]+)', line)
            if m:
                pins[norm(m.group(1))] = m.group(2)
    return pins


# build args every package gets: never the version of the package itself
GLOBAL_ARGS = re.compile(r'(PYTHON|CUDA|L4T|JETPACK|LSB|CUDNN|TENSORRT)_')


def package_version(pkg):
    """Version of a resolved package config: from its name (torchcodec:0.17.0-pytorch:2.12
    -> 0.17.0), else from its only own *_VERSION build arg (onnx -> ONNX_VERSION=1.22.0)."""
    m = re.match(r'\d[\w.]*', pkg['name'].partition(':')[2])
    if m:
        return m[0]
    found = {
        str(v).lstrip('v')
        for k, v in (pkg.get('build_args') or {}).items()
        if k.endswith('_VERSION')
        and not GLOBAL_ARGS.match(k)
        and re.match(r'v?\d', str(v))
    }
    return found.pop() if len(found) == 1 else None


def versioned(entries, resolved):
    """PACKAGES entries with the version of their resolved config added when the
    entry names none (onnx -> onnx:1.22.0); resolved maps entry -> config."""
    out = []
    for entry in entries:
        ver = None if ':' in entry else package_version(resolved[entry])
        out.append(f"{entry}:{ver}" if ver else entry)
    return out


def pip_pins(packages, extra=None):
    """{dist: version} for every versioned package pin plus the extra pip pins."""
    pins = {}
    for pkg in packages:
        if ':' in pkg and re.match(r'\d', pkg.split(':')[1]):
            for dist in dists_for(pkg):
                pins[dist] = pkg.split(':')[1]
    pins.update(extra or {})
    return pins


def version_matches(installed, pin):
    """True if installed satisfies a release-prefix pin: 2.12 ~ 2.12.0, 0.0.35 ~ 0.0.35+abc."""
    release = re.split(r'[+]', installed)[0]
    a, b = release.split('.'), pin.split('.')
    if a[: len(b)] == b:
        return True
    # pin longer than the installed release only when the extra parts are zeros (4.2.0.0 vs 4.2.0)
    return a == b[: len(a)] and all(x == '0' for x in b[len(a) :])


if __name__ == '__main__':  # self-check: python3 package_list.py
    assert package_version({'name': 'torchcodec:0.17.0-pytorch:2.12'}) == '0.17.0'
    assert package_version({'name': 'onnx', 'build_args': {'ONNX_VERSION': '1.22.0'}}) == '1.22.0'
    args = {'PYTHON_VERSION': '3.12', 'TORCH_TRT_VERSION': 'v2.12.0'}
    assert package_version({'name': 'torch_tensorrt', 'build_args': args}) == '2.12.0'
    assert package_version({'name': 'x', 'build_args': {'A_VERSION': '1', 'B_VERSION': '2'}}) is None
    assert pip_pins(['onnx:1.22.0', 'cuda:13.2', 'pytorch:2.12']) == {'onnx': '1.22.0', 'torch': '2.12'}
    assert version_matches('2.12.0+cu132', '2.12') and version_matches('4.2.0', '4.2.0.0')
    assert not version_matches('2.11.0', '2.12')
    assert read_packages(HERE / 'packages.txt')[:2] == ['cuda', 'cudastack:standard']
    print('ok')
