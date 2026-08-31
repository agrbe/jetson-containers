#!/usr/bin/env bash
# =============================================================================
# build.sh
# Builds the jetson-containers CUDA stack image on this Jetson (JetPack 7.2).
#
# Goals:
# - Bring the local devpi/APT servers up before the build and tear them down
#   afterwards, success or failure.
# - Load version pins from .env and export them only to the builder process.
# - Keep the interactive terminal output intact (colors/tty progress) while
#   capturing the full orchestrator log to a file.
# - Store an ANSI-free copy of the log for grep/diagnosis.
#
# Usage:
#   ./build.sh
#
# Optional variables:
#   ENV_FILE=./.env             -> pin file sourced before the build
#   IMAGE_NAME=jetson-models    -> value passed to --name
#   JC_REPO=~/jetson-containers -> repo whose logs/<run>/ receives the final log
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
# --- Build target -------------------------------------------------------------
IMAGE_NAME="${IMAGE_NAME:-jetson-image}"
PACKAGES=(
    cuda
    cudastack:standard
    onnx
    onnxruntime:1.29.0
    pytorch:2.12
    ffmpeg:8.1.2
    torchaudio:2.12.0
)

# --- Environment pins ---------------------------------------------------------
ENV_FILE="${ENV_FILE:-./.env}"

# --- Local package servers ----------------------------------------------------
JC_REPO="${JC_REPO:-$HOME/Repositories/jetson-containers}"
DEVPI_COMPOSE_FILE="${JC_REPO}/packages/net/devpi/compose.yml"

# --- Logging ------------------------------------------------------------------
# The log is written locally first, then moved into the per-run directory that
# jetson-containers creates under $JC_REPO/logs (e.g. logs/20260817_153319/).
LOG="build_$(date +%Y%m%d_%H%M%S).log"
# ──────────────────────────────────────────────────────────────────────────────

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

require_command() {
    local cmd="$1"

    # Checking tools upfront keeps failures clear and avoids wasting build time.
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd"
        exit 1
    fi
}

load_env() {
    # Fail with a clear message instead of the terse error 'set -e' would give.
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "Pin file not found: $ENV_FILE"
        exit 1
    fi

    # Auto-export only while sourcing: pins reach the builder (child process)
    # without requiring 'export' lines inside the .env file itself, and the
    # interactive shell that runs this script inherits nothing.
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
}

start_servers() {
    # launch_pypi.sh starts devpi + APT and only returns once both answered.
    # It also rewrites .env with the resolved URLs and upload credentials, so
    # .env has to be sourced after it, not before.
    "${JC_REPO}/launch_pypi.sh"
    load_env
}

print_config() {
    echo "-----------------------------------------------------------------------------"
    echo "Image:    $IMAGE_NAME"
    echo "Packages: ${PACKAGES[*]}"
    echo "Pins:     $ENV_FILE"
    echo "Wheels:   ${DEVPI_URL:-<absent>}"
    echo "Tarballs: ${LOCAL_TAR_INDEX_URL:-<absent>}"
    echo "Log:      $LOG"
    echo "-----------------------------------------------------------------------------"
}

run_build() {
    local build_cmd

    # 'script' allocates a PTY so the builder still renders colors and tty
    # progress on screen, while everything is captured raw into $LOG.
    # '-e' propagates the real build exit code through 'script'.
    build_cmd="jetson-containers build --buildkit-progress=plain --name=${IMAGE_NAME} ${PACKAGES[*]}"
    script -q -e -c "$build_cmd" "$LOG"
}

cleanup() {
    # Runs on EXIT (success or failure) so the servers are always stopped and
    # the log is always consolidated. $? is captured first and re-raised last,
    # so nothing in here can mask the build's exit code.
    local status=$?
    local run_dir

    echo "==> Stopping the local servers..."
    docker compose -p devpi-local -f "$DEVPI_COMPOSE_FILE" down || true

    if [[ -f "$LOG" ]]; then
        # Strip ANSI escape sequences in place ('script' captures the raw tty).
        sed -i 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG"

        # Newest run directory created by jetson-containers during this run.
        # If none appeared (build failed early), keep the log where it is.
        run_dir="$(ls -1dt "${JC_REPO}/logs"/*/ 2>/dev/null | head -n1 || true)"
        if [[ -n "$run_dir" && "$run_dir" != "$PRE_BUILD_RUN_DIR" ]]; then
            mv "$LOG" "$run_dir"
            echo "Log: ${run_dir}${LOG}"
        else
            echo "Log: ./${LOG} (run directory not identified)"
        fi
    fi

    return "$status"
}

# -----------------------------------------------------------------------------
# Requirement checks
# -----------------------------------------------------------------------------

require_command jetson-containers
require_command script
require_command sed
require_command docker

# -----------------------------------------------------------------------------
# Build execution
# -----------------------------------------------------------------------------

# Snapshot the newest run dir BEFORE building: comparing afterwards tells us
# whether this execution actually created a new logs/<timestamp>/ directory.
PRE_BUILD_RUN_DIR="$(ls -1dt "${JC_REPO}/logs"/*/ 2>/dev/null | head -n1 || true)"

# Registered before the servers start so they are torn down even if the build
# never gets going.
trap cleanup EXIT

start_servers
print_config

run_build
