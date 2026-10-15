def torch2trt(version, ref=None, sha=None, default=False):
    pkg = package.copy()

    pkg['name'] = f'torch2trt:{version}'
    pkg['build_args'] = {
        'TORCH2TRT_REF': ref or f'v{version}',
        'TORCH2TRT_SHA': sha or '',
    }

    if default:
        pkg['alias'] = 'torch2trt'

    return pkg


package = [
    # master: the v0.5.0 tag predates the TensorRT 10 API (execute_async_v2 was removed);
    # master has been unchanged since 2024-05 (4e820ae) and is what was tested;
    # the sha fails the build if master moves.
    torch2trt('0.5.0', ref='master', sha='4e820ae31b4e35d59685935223b05b2e11d47b03', default=True),
]
