#!/usr/bin/env bash
set -ex

if [ "$FORCE_BUILD" == "on" ]; then
	echo "Forcing build of apache-tvm-ffi ${APACHE_TVM_FFI_VERSION}"
	exit 1
fi

uv pip install apache-tvm-ffi==${APACHE_TVM_FFI_VERSION}
