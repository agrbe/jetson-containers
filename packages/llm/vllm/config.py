from jetson_containers import IS_SBSA, update_dependencies, cuda_short_version
from packages.cuda.cutlass.version import CUTLASS_DSL_VERSION


def vllm(version, branch=None, requires=None, default=False, depends=None):
    pkg = package.copy()

    if requires:
        pkg['requires'] = requires

    if depends:
        pkg['depends'] = update_dependencies(pkg['depends'], depends)

    suffix = branch if branch else version
    branch = branch if branch else f'v{version}'

    pkg['name'] = f'vllm:{suffix}'
    pkg['build_args'] = {
        'VLLM_VERSION': version,
        'VLLM_BRANCH': branch,
        'IS_SBSA': IS_SBSA,
        'CUDA_SUFFIX': cuda_short_version(),
        'CUTLASS_DSL_VERSION': CUTLASS_DSL_VERSION,
    }

    builder = pkg.copy()
    builder['name'] = f'vllm:{suffix}-builder'
    builder['build_args'] = {**pkg['build_args'], **{'FORCE_BUILD': 'on'}}

    if default:
        pkg['alias'] = 'vllm'
        builder['alias'] = 'vllm:builder'

    return pkg, builder

package = [
    vllm('0.28.0', depends=['flashinfer'], default=False),
    vllm('0.31.0', depends=['flashinfer'], default=True),
]
