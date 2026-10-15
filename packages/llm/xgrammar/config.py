from jetson_containers import CUDA_VERSION, IS_SBSA
from packaging.version import Version

def xgrammar(version, compressed_tensors, branch=None, requires=None, default=False):
    pkg = package.copy()

    if requires:
        pkg['requires'] = requires

    suffix = branch if branch else version
    branch = branch if branch else f'v{version}'

    pkg['name'] = f'xgrammar:{suffix}'

    pkg['build_args'] = {
        'XGRAMMAR_VERSION': version,
        'COMPRESSED_TENSORS_VERSION': compressed_tensors,
        'IS_SBSA': IS_SBSA
    }

    builder = pkg.copy()

    builder['name'] = f'xgrammar:{suffix}-builder'
    builder['build_args'] = {**pkg['build_args'], **{'FORCE_BUILD': 'on'}}

    if default:
        pkg['alias'] = 'xgrammar'
        builder['alias'] = 'xgrammar:builder'

    return pkg, builder

package = [
    # 0.6.5 compatible with jetson https://github.com/xgrammar-project/xgrammar/pull/9735
    # compressed_tensors: not an xgrammar dependency; the version vllm pins, installed once here
    xgrammar(version='0.2.0', compressed_tensors='0.17.0', default=False),
    xgrammar(version='0.2.7', compressed_tensors='0.17.0', default=True),
]
