"""Package list helpers shared by collect_requirements.py and audit.py.

Reads the PACKAGES pins from a build script, extra pip pins from a
requirements-style file, and maps jetson-containers package names to the
pip distributions they install.
"""

import os
import re
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


def read_packages(build_sh):
    """Entries of the PACKAGES=( ... ) array in build_sh, comments removed."""
    text = Path(build_sh).read_text()
    block = re.search(r'^PACKAGES=\((.*?)^\)', text, re.S | re.M)
    if not block:
        raise ValueError(f"no PACKAGES=( ... ) array in {build_sh}")
    return [
        line.split('#')[0].strip()
        for line in block.group(1).splitlines()
        if line.split('#')[0].strip()
    ]


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
