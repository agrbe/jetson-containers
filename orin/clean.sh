#!/usr/bin/env bash
# =============================================================================
# clean.sh
# Frees disk space used by the build caches.
#
# Goals:
# - Remove by default only what is cheap to rebuild: the uv and pip download
#   caches, refetched on the next install.
# - Require an explicit flag for anything whose loss costs compile time: the
#   BuildKit cache, the ccache mount, the images.
# - Print every target with its size and the total to be freed, then ask for
#   confirmation before deleting anything.
#
# Usage:
#   ./clean.sh                 # uv + pip
#   ./clean.sh --ccache        # + the ccache mount inside BuildKit
#   ./clean.sh --buildkit      # + the whole BuildKit cache (implies --ccache)
#   ./clean.sh --images        # + unused docker images
#   ./clean.sh --all           # everything above
#   ./clean.sh --dry-run       # report only, never prompts, never deletes
#   ./clean.sh --yes           # skip the confirmation prompt
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
# --- Cache locations ----------------------------------------------------------
UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-$HOME/.cache/pip}"

# --- Behavior flags -----------------------------------------------------------
CLEAN_CCACHE=0
CLEAN_BUILDKIT=0
CLEAN_IMAGES=0
DRY_RUN=0
ASSUME_YES=0

# --- Reporting state ----------------------------------------------------------
TOTAL_BYTES=0
# ──────────────────────────────────────────────────────────────────────────────

# =============================================================================
# Helper functions
# =============================================================================

usage() {
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

require_command() {
    local cmd="$1"

    # Checking upfront keeps the failure clear instead of aborting halfway
    # through a multi-step cleanup.
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd"
        exit 1
    fi
}

disk_free() {
    df -h --output=avail / | tail -1 | tr -d ' '
}

dir_size() {
    # Prints a human-readable size, or a dash when the path is absent.
    [[ -d "$1" ]] && du -sh "$1" 2>/dev/null | cut -f1 || echo "-"
}

to_bytes() {
    # Parses both notations in play: docker's SI strings ("30.07GB", "4.096kB")
    # and du -h's binary ones ("1.8M"). The mix makes the total approximate,
    # which is why it is printed with a '~'.
    local value="${1:-}"
    local number unit

    [[ -z "$value" || "$value" == "-" ]] && { echo 0; return 0; }

    number="${value//[^0-9.]/}"
    unit="${value//[0-9.]/}"
    [[ -z "$number" ]] && { echo 0; return 0; }

    case "${unit^^}" in
        ''|B)  awk -v n="$number" 'BEGIN{printf "%.0f", n}' ;;
        KB|K)  awk -v n="$number" 'BEGIN{printf "%.0f", n*1024}' ;;
        MB|M)  awk -v n="$number" 'BEGIN{printf "%.0f", n*1024*1024}' ;;
        GB|G)  awk -v n="$number" 'BEGIN{printf "%.0f", n*1024*1024*1024}' ;;
        TB|T)  awk -v n="$number" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}' ;;
        *)     echo 0 ;;
    esac
}

human() {
    numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"
}

is_bounded_cache_dir() {
    # Only paths under $HOME/.cache may be deleted, so a UV_CACHE_DIR or
    # PIP_CACHE_DIR pointing at $HOME, / or the repository is refused. This has
    # to gate the tool-provided cleaners too, not just the rm: 'uv cache clean'
    # honours UV_CACHE_DIR and would happily wipe whatever it names.
    local target="$1"
    local resolved

    [[ -d "$target" ]] || return 0
    resolved="$(cd "$target" && pwd -P)"

    case "$resolved" in
        "$HOME"/.cache/?*) return 0 ;;
        *)
            echo "    REFUSED  outside ~/.cache: $resolved"
            return 1
            ;;
    esac
}

remove_cache_dir() {
    local target="$1"

    [[ -d "$target" ]] || return 0
    rm -rf "$target"
}

# =============================================================================
# Docker inspection
# =============================================================================

docker_size() {
    # --format keeps the lookup off column positions: the "Build Cache" row has
    # a space in its type, so field indexes differ between rows.
    docker system df --format '{{.Type}}|{{.Size}}' 2>/dev/null \
        | awk -F'|' -v t="$1" '$1 == t {print $2; exit}'
}

cachemount_size() {
    # The ccache is one exec.cachemount record inside the BuildKit store.
    docker buildx du --verbose 2>/dev/null | awk '
        /^Size:/{sz=$2}
        /^Type:/{if ($2 == "exec.cachemount") {print sz; found=1; exit}}
        END{if (!found) print "-"}'
}

# =============================================================================
# Reporting and confirmation
# =============================================================================

report_row() {
    # Prints one target and adds it to TOTAL_BYTES when it is going to be
    # removed, so the total reflects the flags actually given.
    local label="$1"
    local size="$2"
    local selected="$3"
    local action=keep

    if (( selected )); then
        action=clean
        TOTAL_BYTES=$(( TOTAL_BYTES + $(to_bytes "$size") ))
    fi

    printf '%-30s %12s  %s\n' "$label" "$size" "$action"
}

print_targets() {
    TOTAL_BYTES=0

    echo "-----------------------------------------------------------------------------"
    printf '%-30s %12s  %s\n' "TARGET" "SIZE" "ACTION"
    report_row "~/.cache/uv"            "$(dir_size "$UV_CACHE_DIR")"   1
    report_row "~/.cache/pip"           "$(dir_size "$PIP_CACHE_DIR")"  1
    report_row "BuildKit: ccache mount" "$(cachemount_size)"            "$CLEAN_CCACHE"
    report_row "BuildKit: build cache"  "$(docker_size 'Build Cache')"  "$CLEAN_BUILDKIT"
    report_row "Docker images"          "$(docker_size 'Images')"       "$CLEAN_IMAGES"
    echo "-----------------------------------------------------------------------------"
    echo "To free: ~$(human "$TOTAL_BYTES")   |   Free on / now: $(disk_free)"
    (( DRY_RUN )) && echo "Mode: DRY-RUN (nothing will be deleted)"
    echo "-----------------------------------------------------------------------------"
}

confirm() {
    local answer

    (( DRY_RUN ))    && return 0
    (( ASSUME_YES )) && { echo "--yes given, proceeding."; return 0; }

    # Read from the terminal rather than stdin so the prompt survives a piped
    # stdout. A '-r' test is not enough: /dev/tty exists and looks readable even
    # with no controlling terminal, and only the open fails.
    if ! ( : </dev/tty ) 2>/dev/null; then
        echo "No terminal to confirm on. Use --yes to run unattended."
        exit 1
    fi
    exec 3</dev/tty

    while true; do
        read -r -u 3 -p "Delete everything marked 'clean'? [y/N]: " answer
        case "${answer,,}" in
            y|yes)   exec 3<&-; return 0 ;;
            ''|n|no) exec 3<&-; echo "Cancelled. Nothing was deleted."; exit 0 ;;
            *) echo "Answer y or n." ;;
        esac
    done
}

# =============================================================================
# Cleaners
# =============================================================================

clean_uv() {
    echo "==> uv"
    is_bounded_cache_dir "$UV_CACHE_DIR" || return 0

    # 'uv cache clean' knows the layout; the rm covers hosts without uv.
    if command -v uv >/dev/null 2>&1; then
        UV_CACHE_DIR="$UV_CACHE_DIR" uv cache clean >/dev/null 2>&1 \
            || remove_cache_dir "$UV_CACHE_DIR"
    else
        remove_cache_dir "$UV_CACHE_DIR"
    fi
    echo "    OK"
}

clean_pip() {
    echo "==> pip"
    is_bounded_cache_dir "$PIP_CACHE_DIR" || return 0

    if command -v pip3 >/dev/null 2>&1; then
        PIP_CACHE_DIR="$PIP_CACHE_DIR" pip3 cache purge >/dev/null 2>&1 \
            || remove_cache_dir "$PIP_CACHE_DIR"
    else
        remove_cache_dir "$PIP_CACHE_DIR"
    fi
    echo "    OK"
}

clean_ccache() {
    echo "==> ccache (BuildKit type=cache mount)"

    # The ccache lives inside the BuildKit store as an exec.cachemount record,
    # so it is pruned by filter rather than from the filesystem.
    docker buildx prune --filter "type=exec.cachemount" -f 2>&1 | tail -1
}

clean_buildkit() {
    echo "==> BuildKit build cache"

    # -a also drops internal/frontend records. Verified: a populated 41.95MB
    # exec.cachemount is gone after this, which is why --buildkit implies
    # --ccache instead of running both.
    docker buildx prune -af 2>&1 | tail -1
}

clean_images() {
    echo "==> unused docker images"

    docker image prune -af 2>&1 | tail -1
}

# =============================================================================
# Argument parser
# =============================================================================

parse_args() {
    while (( $# )); do
        case "$1" in
            --ccache)   CLEAN_CCACHE=1 ;;
            # A full BuildKit prune removes the cache mount as well, so asking
            # for one implies the other.
            --buildkit) CLEAN_BUILDKIT=1; CLEAN_CCACHE=1 ;;
            --images)   CLEAN_IMAGES=1 ;;
            --all)      CLEAN_CCACHE=1; CLEAN_BUILDKIT=1; CLEAN_IMAGES=1 ;;
            --dry-run)  DRY_RUN=1 ;;
            --yes|-y)   ASSUME_YES=1 ;;
            -h|--help)  usage ;;
            *)
                echo "Unknown argument: $1"
                echo "  Use --help to see the options."
                exit 1
                ;;
        esac
        shift
    done
}

# =============================================================================
# Execution
# =============================================================================

main() {
    parse_args "$@"

    require_command docker
    require_command df
    require_command du
    require_command awk

    print_targets
    confirm

    if (( DRY_RUN )); then
        echo "DRY-RUN: no action taken."
        exit 0
    fi

    clean_uv
    clean_pip

    # A full BuildKit prune already covers the mount, so the narrow filter only
    # runs when the full prune was not requested. Written as 'if' rather than
    # '(( ... )) && cmd' so a false test cannot trip 'set -e'.
    if (( CLEAN_CCACHE && ! CLEAN_BUILDKIT )); then
        clean_ccache
    fi
    if (( CLEAN_BUILDKIT )); then
        clean_buildkit
    fi
    if (( CLEAN_IMAGES )); then
        clean_images
    fi

    echo "-----------------------------------------------------------------------------"
    echo "Free on / after: $(disk_free)"
}

main "$@"
