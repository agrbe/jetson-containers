#!/usr/bin/env bash
# =============================================================================
# build.sh
# Builds the jetson-containers CUDA stack image on this Jetson (JetPack 7.2).
#
# Goals:
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
    python
    onnx
    onnxruntime:1.27.1
)

# --- Environment pins ---------------------------------------------------------
ENV_FILE="${ENV_FILE:-./.env}"
export LSB_RELEASE=24.04
export L4T_VERSION=39.2
export CUDA_VERSION=13.2
export CUDNN_VERSION=9.20
export TENSORRT_VERSION=10.16.2

export LOCAL_PIP_INDEX_URL="https://pypi.org/simple"

# --- Logging ------------------------------------------------------------------
# The log is written locally first, then moved into the per-run directory that
# jetson-containers creates under $JC_REPO/logs (e.g. logs/20260817_153319/).
JC_REPO="${JC_REPO:-$HOME/Repositories/jetson-containers}"
LOG="build_$(date +%Y%m%d_%H%M%S).log"
# ──────────────────────────────────────────────────────────────────────────────

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

require_command() {
    local cmd="$1"

    # Checking tools upfront keeps failures clear and avoids wasting build time.
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Comando obrigatório não encontrado: $cmd"
        exit 1
    fi
}

load_env() {
    # Fail with a clear message instead of the terse error 'set -e' would give.
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "❌ Arquivo de pins não encontrado: $ENV_FILE"
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

print_config() {
    echo "-----------------------------------------------------------------------------"
    echo "Imagem:   $IMAGE_NAME"
    echo "Pacotes:  ${PACKAGES[*]}"
    echo "Pins:     $ENV_FILE"
    echo "Log:      $LOG"
    echo "-----------------------------------------------------------------------------"
}

run_build() {
    local build_cmd

    # 'script' allocates a PTY so the builder still renders colors and tty
    # progress on screen, while everything is captured raw into $LOG.
    # '-e' propagates the real build exit code through 'script'.
    build_cmd="jetson-containers build --name=${IMAGE_NAME} ${PACKAGES[*]}"
    script -q -e -c "$build_cmd" "$LOG"
}

finalize_log() {
    # Runs on EXIT (success or failure) so the log is sanitized and co-located
    # with the per-run files even when the build breaks. $? is preserved.
    local status=$?
    local run_dir

    [[ -f "$LOG" ]] || return "$status"

    # Strip ANSI escape sequences in place ('script' captures the raw tty).
    sed -i 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG"

    # Newest run directory created by jetson-containers during this execution.
    # If none appeared (build failed before logging started), keep the log here.
    run_dir="$(ls -1dt "${JC_REPO}/logs"/*/ 2>/dev/null | head -n1 || true)"
    if [[ -n "$run_dir" && "$run_dir" != "$PRE_BUILD_RUN_DIR" ]]; then
        mv "$LOG" "$run_dir"
        echo "📄 Log consolidado: ${run_dir}${LOG}"
    else
        echo "📄 Log consolidado: ./${LOG} (diretório de run não identificado)"
    fi

    return "$status"
}

# -----------------------------------------------------------------------------
# Requirement checks
# -----------------------------------------------------------------------------

require_command jetson-containers
require_command script
require_command sed

# -----------------------------------------------------------------------------
# Build execution
# -----------------------------------------------------------------------------

# load_env
print_config

# Snapshot the newest run dir BEFORE building: comparing afterwards tells us
# whether this execution actually created a new logs/<timestamp>/ directory.
PRE_BUILD_RUN_DIR="$(ls -1dt "${JC_REPO}/logs"/*/ 2>/dev/null | head -n1 || true)"
trap finalize_log EXIT

run_build
