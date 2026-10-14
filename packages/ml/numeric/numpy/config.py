from jetson_containers import CUDA_VERSION, IS_SBSA
from packaging.version import Version

if CUDA_VERSION < Version('12.6'):
    NUMPY_PACKAGE = 'numpy<2'
    NUMPY_VERSION_MAJOR = 1
else:
    # 2.3.x is the only range every package of the cu13 stack accepts:
    # tensorrt_edgellm >=2.2.6, opencv >=2, mistral_common <2.4, numba <2.5
    NUMPY_PACKAGE = 'numpy==2.3.5'
    NUMPY_VERSION_MAJOR = 2

if IS_SBSA:
    ARCH_OPT = "NEOVERSEV2"
else:
    ARCH_OPT = "ARMV8"

package['build_args'] = {
    'NUMPY_PACKAGE': NUMPY_PACKAGE,
    'NUMPY_VERSION_MAJOR': NUMPY_VERSION_MAJOR,
    'IS_SBSA': IS_SBSA,
    'ARCH_OPT': ARCH_OPT,
}
