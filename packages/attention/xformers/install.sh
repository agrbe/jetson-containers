#!/usr/bin/env bash
set -ex

if [ "$FORCE_BUILD" == "on" ]; then
	echo "Forcing build of xformers ${XFORMERS}"
	exit 1
fi

uv pip install xformers==${XFORMERS_VERSION}
# mslk is served by devpi (uploaded by build.sh); fall back to the PyTorch index until it is
uv pip install mslk==${MSLK_VERSION} ||
uv pip install mslk==${MSLK_VERSION} --default-index https://download.pytorch.org/whl/cu132
