#!/usr/bin/env bash
# =============================================================================
# clean.sh
# Frees disk space used by the build caches and by the local Docker state.
#
# Goals:
# - Leave the machine with no leftover containers: running ones are stopped and
#   then removed. A container in any state pins the image it was created from,
#   so image pruning cannot reclaim that space while it exists.
# - Remove by default only the caches that are cheap to rebuild: the uv and pip
#   download caches, refetched on the next install.
# - Require an explicit flag for anything whose loss costs compile time: the
#   BuildKit cache, the ccache mount, the images.
# - Print every target with its size and the total to be freed, then ask for
#   confirmation before deleting anything.
#
# Usage:
#   ./clean.sh                     # stop + remove containers, then uv and pip
#   ./clean.sh --keep-running      # leave the running containers alone
#   ./clean.sh --no-rm-containers  # stop them, but keep them
#   ./clean.sh --ccache            # + the ccache mount inside BuildKit
#   ./clean.sh --buildkit          # + the whole BuildKit cache (covers --ccache)
#   ./clean.sh --images            # + unused docker images
#   ./clean.sh --nuke              # + every docker object: networks, volumes
#   ./clean.sh --force-nuke        # --nuke without the typed NUKE prompt
#   ./clean.sh --dry-run           # report only, never prompts, never deletes
#   ./clean.sh --yes               # skip the [y/N] prompt, never the NUKE one
#
# Warning:
#   build.sh runs the local devpi and APT servers as compose project
#   'devpi-local'. The default stop and remove aborts a build in progress and
#   makes publish.sh fail; pass --keep-running while a build is running.
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
# --- Cache locations ----------------------------------------------------------
UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-$HOME/.cache/pip}"

# --- Local package servers ----------------------------------------------------
# Compose project name used by build.sh, matched by label to warn before the
# servers are stopped from under a running build.
DEVPI_COMPOSE_PROJECT="devpi-local"

# --- Behavior flags -----------------------------------------------------------
# STOP_RUNNING and RM_CONTAINERS are the only opt-out switches in the script:
# they default to 1 and their flags turn them off.
STOP_RUNNING=1
RM_CONTAINERS=1
CLEAN_CCACHE=0
CLEAN_BUILDKIT=0
CLEAN_IMAGES=0
NUKE=0
FORCE_NUKE=0
DRY_RUN=0
ASSUME_YES=0

# --- Reporting state ----------------------------------------------------------
TOTAL_BYTES=0
# Set by resolve_flags when a wider prune already accounts for the ccache mount.
CCACHE_SUBSUMED=0
# ──────────────────────────────────────────────────────────────────────────────

# =============================================================================
# Helper functions
# =============================================================================

usage() {
    # Print from the line after the opening banner up to the closing one, so the
    # range never needs updating when the header grows. 'Q' quits without
    # printing the banner itself.
    sed -n '3,$p' "${BASH_SOURCE[0]}" | sed '/^# =\{5,\}/Q; s/^# \{0,1\}//'
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
    # which is why it is printed with a '~'. There is deliberately no IEC arm:
    # human() emits IEC, so a human() -> to_bytes() round-trip would silently
    # fall through to 0. Never feed this function its own output.
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
    # a space in its type, so field indexes differ between rows. The same is
    # true of "Local Volumes".
    #
    # Deliberately '.Size' and not '.Reclaimable': docker computes the images
    # reclaimable figure by summing each image's unique size, which ignores that
    # shared base layers are freed too once every image referencing them is
    # gone. With the containers removed first, '.Size' is the accurate estimate
    # and '.Reclaimable' understates it several times over.
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

running_count() {
    local -a ids

    mapfile -t ids < <(docker ps -q 2>/dev/null)
    echo "${#ids[@]}"
}

devpi_is_running() {
    # build.sh starts devpi and the APT server as compose project 'devpi-local',
    # and publish.sh refuses to run without them. '--filter' exits 0 with empty
    # output when nothing matches, so the substitution is safe under 'set -e'.
    local ids

    ids="$(docker ps -q \
        --filter "label=com.docker.compose.project=$DEVPI_COMPOSE_PROJECT" \
        2>/dev/null)"
    [[ -n "$ids" ]]
}

# =============================================================================
# Reporting and confirmation
# =============================================================================

report_row() {
    # Prints one target and adds it to TOTAL_BYTES when it is going to be
    # removed, so the total reflects the flags actually given. 'subsumed' marks
    # a target a wider prune already accounts for: it still shows as selected,
    # but contributes nothing, otherwise its bytes would be counted twice.
    local label="$1"
    local size="$2"
    local selected="$3"
    local subsumed="${4:-0}"
    local action="${5:-keep}"

    if (( selected )); then
        if (( subsumed )); then
            action='clean*'
        else
            action=clean
            TOTAL_BYTES=$(( TOTAL_BYTES + $(to_bytes "$size") ))
        fi
    fi

    printf '%-30s %12s  %s\n' "$label" "$size" "$action"
}

warn_devpi() {
    if ! (( STOP_RUNNING || RM_CONTAINERS || NUKE )); then
        return 0
    fi
    if ! devpi_is_running; then
        return 0
    fi

    echo "WARNING  the local package servers (${DEVPI_COMPOSE_PROJECT}) are running."
    echo "         Stopping them aborts a build.sh in progress and breaks publish.sh."
    echo "         Restart them with ./launch_pypi.sh, or re-run with --keep-running."
    echo "         Their data lives on bind mounts, so no prune here drops the index."
    echo "-----------------------------------------------------------------------------"
}

print_targets() {
    local containers_action=keep

    TOTAL_BYTES=0
    if (( STOP_RUNNING )); then
        containers_action=stop
    fi

    echo "-----------------------------------------------------------------------------"
    printf '%-30s %12s  %s\n' "TARGET" "SIZE" "ACTION"
    # Rows follow the order in which main() acts on them.
    report_row "Containers (run: $(running_count))" \
               "$(docker_size 'Containers')"     "$RM_CONTAINERS" 0 "$containers_action"
    report_row "Docker volumes (local)"  "$(docker_size 'Local Volumes')" "$NUKE"
    report_row "~/.cache/uv"             "$(dir_size "$UV_CACHE_DIR")"    1
    report_row "~/.cache/pip"            "$(dir_size "$PIP_CACHE_DIR")"   1
    report_row "BuildKit: ccache mount"  "$(cachemount_size)" \
               "$CLEAN_CCACHE" "$CCACHE_SUBSUMED"
    report_row "BuildKit: build cache"   "$(docker_size 'Build Cache')"   "$CLEAN_BUILDKIT"
    report_row "Docker images"           "$(docker_size 'Images')"        "$CLEAN_IMAGES"
    echo "-----------------------------------------------------------------------------"
    echo "To free: ~$(human "$TOTAL_BYTES")   |   Free on / now: $(disk_free)"
    if (( CLEAN_CCACHE && CCACHE_SUBSUMED )); then
        echo "* already counted inside a larger target"
    fi
    if (( ! RM_CONTAINERS )); then
        echo "Containers are kept, so the image figure is an upper bound."
    fi
    if (( DRY_RUN )); then
        echo "Mode: DRY-RUN (nothing will be deleted)"
    fi
    echo "-----------------------------------------------------------------------------"
    warn_devpi
}

open_tty() {
    # Read from the terminal rather than stdin so the prompt survives a piped
    # stdout. A '-r' test is not enough: /dev/tty exists and looks readable even
    # with no controlling terminal, and only the open fails.
    if ! ( : </dev/tty ) 2>/dev/null; then
        echo "No terminal to confirm on."
        echo "  Use --yes to skip the [y/N] prompt, and --force-nuke for --nuke."
        exit 1
    fi
    exec 3</dev/tty
}

ask_yes_no() {
    local answer

    while true; do
        # A failing read means the descriptor was closed with Ctrl-D. Treating
        # it as a deliberate abort keeps 'set -e' from killing the script with
        # status 1 and no message at all.
        if ! read -r -u 3 -p "Delete everything marked 'clean'? [y/N]: " answer; then
            echo
            echo "Cancelled. Nothing was deleted."
            exit 0
        fi
        case "${answer,,}" in
            y|yes)   return 0 ;;
            ''|n|no) echo "Cancelled. Nothing was deleted."; exit 0 ;;
            *) echo "Answer y or n." ;;
        esac
    done
}

ask_nuke() {
    local answer

    # Blank line so the warning does not run into the answer just typed.
    echo
    echo "A total prune removes every unused image, the whole build cache, all"
    echo "stopped containers, unused networks and unused volumes, including named"
    echo "volumes belonging to other projects on this machine."
    # Single shot and case-sensitive on purpose: a prompt this destructive
    # should not invite a second attempt.
    if ! read -r -u 3 -p "Type NUKE to confirm: " answer; then
        echo
        echo "Cancelled. Nothing was deleted."
        exit 0
    fi
    if [[ "$answer" != "NUKE" ]]; then
        echo "Not confirmed. Nothing was deleted."
        exit 0
    fi
}

confirm() {
    local need_yesno=1
    local need_nuke=0

    if (( DRY_RUN )); then
        return 0
    fi
    if (( ASSUME_YES )); then
        need_yesno=0
    fi
    # --yes covers the ordinary prompt only; the typed confirmation is the whole
    # point of --nuke and is waived exclusively by --force-nuke.
    if (( NUKE && ! FORCE_NUKE )); then
        need_nuke=1
    fi
    if (( ! need_yesno && ! need_nuke )); then
        echo "--yes given, proceeding."
        return 0
    fi

    open_tty
    if (( need_yesno )); then
        ask_yes_no
    fi
    if (( need_nuke )); then
        ask_nuke
    fi
    exec 3<&-
}

# =============================================================================
# Cleaners
# =============================================================================

stop_containers() {
    local -a ids

    if (( ! STOP_RUNNING )); then
        return 0
    fi

    echo "==> stopping running containers"
    # The array is not optional: 'docker stop' with no arguments exits 1, which
    # would abort the whole script on an idle host under 'set -e'.
    mapfile -t ids < <(docker ps -q 2>/dev/null)
    if (( ! ${#ids[@]} )); then
        echo "    none running"
        return 0
    fi
    docker stop "${ids[@]}" >/dev/null
    echo "    stopped ${#ids[@]}"
}

remove_containers() {
    if (( ! RM_CONTAINERS )); then
        return 0
    fi

    echo "==> removing containers"
    # 'container prune' touches stopped containers only. That is what makes
    # --keep-running protect a running devpi: no 'rm -f' is ever issued.
    docker container prune -f 2>&1 | tail -1
}

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
    # exec.cachemount is gone after this, which is why --buildkit subsumes
    # --ccache instead of running both.
    docker buildx prune -af 2>&1 | tail -1
}

clean_images() {
    echo "==> unused docker images"

    docker image prune -af 2>&1 | tail -1
}

clean_nuke() {
    echo "==> NUKE: images, build cache, containers, networks, volumes"

    # buildx runs first so the cache is reached under a docker-container driver
    # too, where a daemon-level system prune would not see it. Each step is
    # guarded because 'pipefail' would otherwise abort before the later passes.
    docker buildx prune -af           2>&1 | tail -1 || true
    docker system prune -af --volumes 2>&1 | tail -1 || true
    # 'system prune --volumes' removes anonymous volumes only; named unused
    # volumes need a pass of their own.
    docker volume prune -af           2>&1 | tail -1 || true
}

# =============================================================================
# Argument parser
# =============================================================================

parse_args() {
    while (( $# )); do
        case "$1" in
            --keep-running)     STOP_RUNNING=0 ;;
            --no-rm-containers) RM_CONTAINERS=0 ;;
            --ccache)           CLEAN_CCACHE=1 ;;
            --buildkit)         CLEAN_BUILDKIT=1 ;;
            --images)           CLEAN_IMAGES=1 ;;
            --nuke)             NUKE=1 ;;
            --force-nuke)       NUKE=1; FORCE_NUKE=1 ;;
            --dry-run)          DRY_RUN=1 ;;
            --yes|-y)           ASSUME_YES=1 ;;
            -h|--help)          usage ;;
            *)
                echo "Unknown argument: $1"
                echo "  Use --help to see the options."
                exit 1
                ;;
        esac
        shift
    done
}

resolve_flags() {
    # Every flag implication lives here, and this runs before the report, so the
    # ACTION column can never disagree with what main() goes on to do.
    if (( NUKE )); then
        if (( ! STOP_RUNNING )); then
            echo "--nuke cannot honour --keep-running: a total prune stops everything."
            exit 1
        fi
        # A total prune covers every docker-side target, so the granular flags
        # are turned on for the report while main() skips their cleaners.
        CLEAN_CCACHE=1
        CLEAN_BUILDKIT=1
        CLEAN_IMAGES=1
        RM_CONTAINERS=1
    fi
    if (( CLEAN_BUILDKIT )); then
        CLEAN_CCACHE=1
        CCACHE_SUBSUMED=1
    fi

    # An arithmetic test as the last statement would make this function return 1
    # whenever the flag is 0, and that status does trip 'set -e' in the caller.
    return 0
}

# =============================================================================
# Execution
# =============================================================================

main() {
    parse_args "$@"
    resolve_flags

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

    # Containers pin both the image they were created from and the volumes they
    # mount, in any state. Image, volume and system prunes only reclaim the full
    # amount once the containers are gone, so this order is required.
    stop_containers
    remove_containers

    clean_uv
    clean_pip

    if (( NUKE )); then
        # The destructive superset runs last, so a failure here still leaves the
        # cheap reclaims above already banked.
        clean_nuke
    else
        # A full BuildKit prune already covers the mount, so the narrow filter
        # only runs when the full prune was not requested. Written as 'if'
        # rather than '(( ... )) && cmd' to keep the style uniform with the
        # rest of the script.
        if (( CLEAN_CCACHE && ! CLEAN_BUILDKIT )); then
            clean_ccache
        fi
        if (( CLEAN_BUILDKIT )); then
            clean_buildkit
        fi
        if (( CLEAN_IMAGES )); then
            clean_images
        fi
    fi

    echo "-----------------------------------------------------------------------------"
    echo "Free on / after: $(disk_free)"
}

main "$@"
