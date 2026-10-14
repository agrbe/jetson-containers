def apache_tvm_ffi(version, requires=None, default=False):
    pkg = package.copy()

    if requires:
        pkg['requires'] = requires

    pkg['name'] = f'apache-tvm-ffi:{version}'

    pkg['build_args'] = {
        'APACHE_TVM_FFI_VERSION': version,
    }

    builder = pkg.copy()

    builder['name'] = f'apache-tvm-ffi:{version}-builder'
    builder['build_args'] = {**pkg['build_args'], **{'FORCE_BUILD': 'on'}}

    if default:
        pkg['alias'] = 'apache-tvm-ffi'
        builder['alias'] = 'apache-tvm-ffi:builder'

    return pkg, builder


package = [
    # vllm 0.31 needs ==0.1.11, nvidia-cudnn-frontend 1.31 >=0.1.11, tilelang <=0.1.11;
    # flashinfer, xgrammar and mamba (declares <=0.1.9) work with it
    apache_tvm_ffi('0.1.11', default=True),
]
