#!/usr/bin/env bash
# Stops the local PyPI (devpi) + APT servers started by launch_pypi.sh.
# The caches (wheels, tarballs and the devpi database) are kept, so the next
# launch_pypi.sh serves the same artifacts. The .env block written by
# launch_pypi.sh is left in place; launch_pypi.sh rewrites it on every run.
set -e

ROOT="$(dirname "$(readlink -f "$0")")"
DEVPI_DIR="${ROOT}/packages/net/devpi"
COMPOSE_FILE="${DEVPI_DIR}/compose.yml"
COMPOSE_PROJECT="devpi-local"

compose() {
    docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" "$@"
}

echo "========================================="
echo " Stopping local PyPI + APT servers"
echo "========================================="

if [ -z "$(compose ps -q 2>/dev/null)" ] && [ -z "$(docker ps -aq -f name=^devpi-local$)" ]; then
    echo ""
    echo "    No local servers are running."
    exit 0
fi

echo ""
echo "==> Stopping services..."
compose down

# Container left by older docker-run based launches
docker rm -f devpi-local >/dev/null 2>&1 || true

echo ""
echo "========================================="
echo " Local servers stopped"
echo "========================================="
echo ""
echo " Caches kept in: ${DEVPI_DIR}/cache"
echo " To start again: ${ROOT}/launch_pypi.sh"
echo ""
