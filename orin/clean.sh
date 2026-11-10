#!/usr/bin/env bash
# =============================================================================
# clean.sh
# Frees disk space used by the jetson-containers build: images, BuildKit cache
# (including the ccache mount) and the host uv/pip caches.
#
# Goals:
# - Default mode is cheap and safe to run after every successful build: a
#   rebuild right after it is still fully CACHED.
# - Every mode prints what it removes, with sizes, before acting; --dry-run
#   stops there.
# - Work non-interactively: no prompt, the mode flag is the confirmation and
#   --dry-run is the preview.
# - Never touch the devpi/APT data: it lives on bind mounts under
#   packages/net/devpi/cache, which no docker prune can reach.
# - Verify the BuildKit prune instead of trusting it: records BuildKit holds as
#   in use survive 'prune -af' while it still exits 0. When that leftover is
#   real, --cache and --nuke restart the daemon (root or passwordless sudo, or
#   a sudo prompt on a terminal) and prune again; otherwise they say how.
#
# Usage:
#   ./clean.sh                 # default: uv/pip caches, dangling images, images
#                              #   of old builds outside the current chain, and
#                              #   BuildKit records the current chain did not use
#                              #   (the ccache mount is always kept)
#   ./clean.sh --cache         # every cache: uv/pip, whole BuildKit cache, ccache
#   ./clean.sh --images        # stage images (<name>:*-<stage>) and dangling ones;
#                              #   final images and devpi/apt images are kept
#   ./clean.sh --nuke          # everything: all containers, images, volumes,
#                              #   networks, BuildKit cache and build history
#   ./clean.sh --dry-run ...   # report only, combinable with any mode
#
# The current chain:
#   The newest logs/<run>/ whose build/NNoMM_*.sh covers all MM stages and whose
#   every stage log reports 'naming to <tag> done', i.e. the last build that
#   finished. --simulate runs write the .sh files but no logs, so they never
#   qualify. Stage tags of newer, unfinished runs are kept as well.
#
# Warning:
#   --nuke stops and removes every container on this host and prunes every
#   unused volume, including those of other projects.
#   A daemon restart aborts any build in progress.
#
# Optional variables:
#   JC_REPO                      repository root (default: parent of this script)
#   CACHE_GRACE_SECONDS          default mode keeps BuildKit records used up to
#                                this long before the current chain's build began
#   BUILDKIT_LEFTOVER_MIN_BYTES  cache left after a prune below this is ignored
#   DOCKER_READY_TIMEOUT         seconds to wait for the daemon after a restart
#   CONTAINERD_NAMESPACE         namespace whose snapshots are counted
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
# --- Locations ----------------------------------------------------------------
JC_REPO="${JC_REPO:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
LOGS_DIR="${JC_REPO}/logs"
UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-$HOME/.cache/pip}"
# Local build refs buildx writes per build; only --nuke clears them.
BUILDX_REFS_DIR="$HOME/.docker/buildx/refs"

# --- Local package servers ----------------------------------------------------
DEVPI_COMPOSE_PROJECT="devpi-local"

# --- Default-mode retention ---------------------------------------------------
# Margin before the chain's build start, so clock rounding never drops a record
# the build touched.
CACHE_GRACE_SECONDS="${CACHE_GRACE_SECONDS:-3600}"

# --- BuildKit verification ----------------------------------------------------
BUILDKIT_LEFTOVER_MIN_BYTES="${BUILDKIT_LEFTOVER_MIN_BYTES:-104857600}"
DOCKER_READY_TIMEOUT="${DOCKER_READY_TIMEOUT:-60}"
CONTAINERD_NAMESPACE="${CONTAINERD_NAMESPACE:-moby}"

# --- Behavior flags -----------------------------------------------------------
CLEAN_CACHE=0
CLEAN_IMAGES=0
NUKE=0
DRY_RUN=0

# --- State --------------------------------------------------------------------
TOTAL_BYTES=0
BUILDKIT_STUCK=0
# Image inventory: ref -> id / unique size.
declare -A IMG_ID=()
declare -A IMG_UNIQUE=()
declare -A TAGS_PER_ID=()
IMG_REFS=()
# Current chain.
CHAIN_RUN=""
CHAIN_ANCHOR=0
CHAIN_OK=0
declare -A KEEP_TAGS=()
declare -A CHAIN_IDS=()
declare -A CHAIN_REPOS=()
# Images selected for removal by the default or --images mode.
DROP_IMAGES=()
# ──────────────────────────────────────────────────────────────────────────────

# =============================================================================
# Helper functions
# =============================================================================

usage() {
    # Print the header between the two banners.
    sed -n '3,$p' "${BASH_SOURCE[0]}" | sed '/^# =\{5,\}/Q; s/^# \{0,1\}//'
    exit 0
}

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd"
        exit 1
    fi
}

disk_free() {
    df -h --output=avail / | tail -1 | tr -d ' '
}

dir_size() {
    [[ -d "$1" ]] && du -sh "$1" 2>/dev/null | cut -f1 || echo "-"
}

to_bytes() {
    # Parses docker's SI strings ("30.07GB", "4.096kB") and du -h's ("1.8M").
    # The mix makes totals approximate, hence the '~'. No IEC arm on purpose:
    # never feed it human()'s output.
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

is_bounded_dir() {
    # Deletion is allowed only below the given root, so a cache variable that
    # points at $HOME, / or the repository is refused. Gates the tool cleaners
    # too: 'uv cache clean' wipes whatever UV_CACHE_DIR names.
    local target="$1"
    local root="$2"
    local resolved

    [[ -d "$target" ]] || return 0
    resolved="$(cd "$target" && pwd -P)"
    case "$resolved" in
        "$root"/?*) return 0 ;;
        *)
            echo "    REFUSED  outside $root: $resolved"
            return 1
            ;;
    esac
}

remove_dir() {
    [[ -d "$1" ]] || return 0
    rm -rf "$1"
}

can_restart_docker() {
    # Non-interactive callers get passwordless sudo or nothing; a terminal may
    # answer a password prompt.
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "    systemctl not found: the docker daemon cannot be restarted."
        return 1
    fi
    if (( EUID == 0 )); then
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        echo "    sudo not found: restarting the docker daemon needs root."
        return 1
    fi
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    if [[ -t 0 ]] && sudo -v; then
        return 0
    fi
    echo "    sudo needs a password and there is no terminal to ask on."
    return 1
}

run_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

# =============================================================================
# Docker inspection
# =============================================================================

docker_size() {
    # '.Size', not '.Reclaimable': docker sums unique sizes for the latter,
    # which ignores shared layers freed once all their images are gone.
    docker system df --format '{{.Type}}|{{.Size}}' 2>/dev/null \
        | awk -F'|' -v t="$1" '$1 == t {print $2; exit}'
}

cachemount_size() {
    # The ccache is one exec.cachemount record inside the BuildKit store.
    { docker buildx du --filter 'type=exec.cachemount' \
        --format '{{.Size}}' 2>/dev/null || true; } \
        | awk 'NR == 1 {print} END{if (NR == 0) print "-"}'
}

buildkit_usage() {
    # "<reclaimable> <total>" from 'buildx du'. Reads to the end so docker
    # never gets SIGPIPE under 'pipefail'.
    { docker buildx du 2>/dev/null || true; } | awk '
        $1 == "Reclaimable:" {r = $2}
        $1 == "Total:"       {t = $2}
        END{print (r == "" ? "-" : r), (t == "" ? "-" : t)}'
}

buildkit_total_bytes() {
    local total

    read -r _ total < <(buildkit_usage)
    to_bytes "$total"
}

buildkit_unused_since() {
    # Preview of the default-mode prune: what 'buildx prune' without -a and
    # with until=<secs>s, type!=exec.cachemount removes. Without -a BuildKit
    # skips internal/frontend records and records shared with images; in-use
    # records are never reclaimable. 'buildx du' only prints LastUsedAt
    # humanized, so the age is approximate (exact up to 48h, then in days).
    local secs="$1"

    { docker buildx du \
        --format '{{.Type}}|{{.Reclaimable}}|{{.Shared}}|{{.LastUsedAt}}|{{.Size}}' \
        2>/dev/null || true; } | awk -F'|' -v cut="$secs" '
        function age(s,   n) {
            if (s == "" || s ~ /nil/) return 1e12
            if (s ~ /^Less than/) return 0
            if (s ~ /^About a minute/) return 60
            if (s ~ /^About an hour/) return 3600
            n = s + 0
            if (s ~ /second/) return n
            if (s ~ /minute/) return n * 60
            if (s ~ /hour/)   return n * 3600
            if (s ~ /day/)    return n * 86400
            if (s ~ /week/)   return n * 604800
            if (s ~ /month/)  return n * 2592000
            return n * 31536000
        }
        $1 == "exec.cachemount" || $1 == "internal" || $1 == "frontend" {next}
        $2 != "true" || $3 == "true" {next}
        age($4) > cut {print $5}'
}

containerd_snapshot_count() {
    # Ground truth for /var/lib/containerd; 'ctr' needs root and 'sudo -n'
    # keeps this informational line from prompting.
    local listing

    if ! command -v ctr >/dev/null 2>&1; then
        echo "-"
        return 0
    fi
    if (( EUID == 0 )); then
        listing="$(ctr -n "$CONTAINERD_NAMESPACE" snapshots ls 2>/dev/null)" \
            || { echo "-"; return 0; }
    else
        listing="$(sudo -n ctr -n "$CONTAINERD_NAMESPACE" snapshots ls 2>/dev/null)" \
            || { echo "-"; return 0; }
    fi
    awk 'NR > 1 && NF {n++} END{print n + 0}' <<<"$listing"
}

running_count() {
    local -a ids

    mapfile -t ids < <(docker ps -q 2>/dev/null)
    echo "${#ids[@]}"
}

devpi_is_running() {
    local ids

    ids="$(docker ps -q \
        --filter "label=com.docker.compose.project=$DEVPI_COMPOSE_PROJECT" \
        2>/dev/null)"
    [[ -n "$ids" ]]
}

history_count() {
    { docker buildx history ls --format '{{.Ref}}' 2>/dev/null || true; } \
        | awk 'NF {n++} END{print n + 0}'
}

load_images() {
    # Tags come from 'image ls': 'system df -v' prints one row per id, so a
    # second tag (the final alias of the last stage) would look missing. The
    # unique size per id comes from 'system df -v': layers shared with kept
    # images are not freed, so summing '.Size' would claim terabytes.
    local line ref id
    local -A unique=()

    while IFS='|' read -r id line; do
        [[ -n "$id" ]] && unique["$id"]="$line"
    done < <(docker system df -v --format \
        '{{range .Images}}{{.ID}}|{{.UniqueSize}}{{println}}{{end}}' 2>/dev/null)

    while IFS='|' read -r ref id; do
        [[ -n "$ref" && "$ref" != *"<none>"* ]] || continue
        IMG_REFS+=("$ref")
        IMG_ID["$ref"]="$id"
        IMG_UNIQUE["$ref"]="${unique[$id]:-0B}"
        TAGS_PER_ID["$id"]=$(( ${TAGS_PER_ID[$id]:-0} + 1 ))
    done < <(docker image ls --no-trunc \
        --format '{{.Repository}}:{{.Tag}}|{{.ID}}' 2>/dev/null)
}

dangling_count() {
    local -a ids

    mapfile -t ids < <(docker image ls -q --filter dangling=true 2>/dev/null)
    echo "${#ids[@]}"
}

# =============================================================================
# Current chain
# =============================================================================

run_tags() {
    # Stage tags of one run, one per build/*.sh.
    local sh

    for sh in "$1"/build/*.sh; do
        [[ -f "$sh" ]] || continue
        grep -o -- '--tag [^ ]*' "$sh" | head -1 | cut -d' ' -f2
    done
}

run_finished() {
    # True when the run has all MM stage scripts and every stage log shows the
    # image was exported under its tag.
    local run="$1"
    local -a shs
    local total sh tag

    shopt -s nullglob
    shs=("$run"/build/[0-9]*o[0-9]*_*.sh)
    shopt -u nullglob
    (( ${#shs[@]} )) || return 1

    total="${shs[0]##*/}"
    total="${total#*o}"
    total="${total%%_*}"
    (( ${#shs[@]} == 10#$total )) || return 1

    for sh in "${shs[@]}"; do
        tag="$(grep -o -- '--tag [^ ]*' "$sh" | head -1 | cut -d' ' -f2)"
        [[ -n "$tag" && -f "${sh%.sh}.txt" ]] || return 1
        grep -F 'naming to ' "${sh%.sh}.txt" | grep -qF -- "${tag} done" || return 1
    done
}

find_chain() {
    # Walks runs newest first; tags of unfinished newer runs are kept too, so a
    # build in progress or a failed one never loses its fresh images.
    local -a runs
    local i run name tag

    shopt -s nullglob
    runs=("$LOGS_DIR"/*/)
    shopt -u nullglob

    for (( i = ${#runs[@]} - 1; i >= 0; i-- )); do
        run="${runs[i]%/}"
        while read -r tag; do
            [[ -n "$tag" ]] && KEEP_TAGS["$tag"]=1
        done < <(run_tags "$run")
        if run_finished "$run"; then
            CHAIN_RUN="$run"
            break
        fi
    done
    [[ -n "$CHAIN_RUN" ]] || return 0

    # The run directory is named after the build start (local time).
    name="${CHAIN_RUN##*/}"
    CHAIN_ANCHOR="$(date -d "${name:0:8} ${name:9:2}:${name:11:2}:${name:13:2}" +%s \
        2>/dev/null || echo 0)"
}

check_chain() {
    # The image and cache parts of the default mode only run when every image
    # of the finished chain exists: otherwise the chain is not what is on disk.
    local tag missing=0

    [[ -n "$CHAIN_RUN" ]] || { echo "Chain: no finished build in $LOGS_DIR"; return 0; }
    if (( ! CHAIN_ANCHOR )); then
        echo "Chain: cannot read the start time of $CHAIN_RUN"
        return 0
    fi
    while read -r tag; do
        [[ -n "$tag" ]] || continue
        CHAIN_REPOS["${tag%:*}"]=1
        if [[ -z "${IMG_ID[$tag]:-}" ]]; then
            echo "Chain: missing image $tag"
            missing=1
        fi
    done < <(run_tags "$CHAIN_RUN")
    for tag in "${!KEEP_TAGS[@]}"; do
        [[ -n "${IMG_ID[$tag]:-}" ]] && CHAIN_IDS["${IMG_ID[$tag]}"]=1
    done
    if (( missing )); then
        echo "Chain: incomplete, old images and BuildKit records are left alone."
        return 0
    fi
    CHAIN_OK=1
    echo "Chain: ${CHAIN_RUN#"$JC_REPO"/} ($(run_tags "$CHAIN_RUN" | wc -l) stages," \
         "started $(date -d "@$CHAIN_ANCHOR" '+%F %T'))"
}

select_old_images() {
    # Same repository as the chain, not a kept tag, and not sharing an id with
    # a kept tag: that last rule keeps the final alias of the last stage.
    local ref

    for ref in "${IMG_REFS[@]}"; do
        [[ -n "${CHAIN_REPOS[${ref%:*}]:-}" ]] || continue
        [[ -z "${KEEP_TAGS[$ref]:-}" ]] || continue
        [[ -z "${CHAIN_IDS[${IMG_ID[$ref]}]:-}" ]] || continue
        DROP_IMAGES+=("$ref")
    done
}

select_stage_images() {
    # A stage image is any tag some logs/<run>/build/*.sh built. The final tag
    # is never a stage tag, and devpi/apt images are built by compose.
    local -A stage=()
    local -a runs
    local run tag ref

    shopt -s nullglob
    runs=("$LOGS_DIR"/*/)
    shopt -u nullglob
    for run in "${runs[@]}"; do
        while read -r tag; do
            [[ -n "$tag" ]] && stage["$tag"]=1
        done < <(run_tags "${run%/}")
    done
    for ref in "${IMG_REFS[@]}"; do
        [[ -n "${stage[$ref]:-}" ]] && DROP_IMAGES+=("$ref")
    done
    return 0
}

# =============================================================================
# Reporting
# =============================================================================

report_row() {
    # Adds the size to TOTAL_BYTES when the action is 'clean'.
    local label="$1"
    local size="$2"
    local action="$3"

    if [[ "$action" == clean ]]; then
        TOTAL_BYTES=$(( TOTAL_BYTES + $(to_bytes "$size") ))
    fi
    printf '%-36s %12s  %s\n' "$label" "$size" "$action"
}

pick() {
    # "clean" when the flag is set, "keep" otherwise.
    if (( $1 )); then echo clean; else echo keep; fi
}

drop_size() {
    # Removing a tag frees the image only when every tag of its id goes.
    local ref="$1"
    local id="${IMG_ID[$ref]}"
    local ref2 dropped=0

    for ref2 in "${DROP_IMAGES[@]}"; do
        [[ "${IMG_ID[$ref2]}" == "$id" ]] && dropped=$(( dropped + 1 ))
    done
    if (( dropped < TAGS_PER_ID[$id] )); then
        echo "0B"
    else
        echo "${IMG_UNIQUE[$ref]}"
    fi
}

images_bytes() {
    # Each id once, so a multi-tag image is not counted per tag.
    local -A seen=()
    local ref total=0

    for ref in "${DROP_IMAGES[@]}"; do
        [[ -z "${seen[${IMG_ID[$ref]}]:-}" ]] || continue
        seen["${IMG_ID[$ref]}"]=1
        total=$(( total + $(to_bytes "$(drop_size "$ref")") ))
    done
    echo "$total"
}

print_targets() {
    local default_mode=$(( ! CLEAN_CACHE && ! CLEAN_IMAGES && ! NUKE ))
    local host_caches=$(( default_mode || CLEAN_CACHE || NUKE ))
    local whole_cache=$(( CLEAN_CACHE || NUKE ))
    local devpi_action=keep secs bk ref

    if devpi_is_running; then
        devpi_action=stop
    fi

    echo "-----------------------------------------------------------------------------"
    printf '%-36s %12s  %s\n' "TARGET" "SIZE" "ACTION"
    report_row "devpi-local servers (data kept)" "-" "$devpi_action"
    if (( NUKE )); then
        report_row "Containers (run: $(running_count))" "$(docker_size 'Containers')" clean
        report_row "Docker volumes (unused)" "$(docker_size 'Local Volumes')" clean
    fi
    report_row "~/.cache/uv" "$(dir_size "$UV_CACHE_DIR")" "$(pick "$host_caches")"
    report_row "~/.cache/pip" "$(dir_size "$PIP_CACHE_DIR")" "$(pick "$host_caches")"
    report_row "BuildKit: ccache mount" "$(cachemount_size)" "$(pick "$whole_cache")"

    if (( whole_cache )); then
        # The ccache figure is inside the build cache one: count it once.
        TOTAL_BYTES=$(( TOTAL_BYTES - $(to_bytes "$(cachemount_size)") ))
        report_row "BuildKit: whole build cache" "$(docker_size 'Build Cache')" clean
    elif (( default_mode && CHAIN_OK )); then
        secs=$(( $(date +%s) - CHAIN_ANCHOR + CACHE_GRACE_SECONDS ))
        bk="$(buildkit_unused_since "$secs" | while read -r s; do to_bytes "$s"; echo; done \
            | awk '{t += $1} END{print t + 0}')"
        # Printed directly: to_bytes must never read human()'s output back.
        printf '%-36s %12s  %s\n' "BuildKit: unused by chain (~)" "$(human "$bk")" clean
        TOTAL_BYTES=$(( TOTAL_BYTES + bk ))
        report_row "BuildKit: build cache (total)" "$(docker_size 'Build Cache')" keep
    else
        report_row "BuildKit: build cache" "$(docker_size 'Build Cache')" keep
    fi

    if (( NUKE )); then
        report_row "BuildKit: build history ($(history_count))" "-" clean
        report_row "~/.docker/buildx/refs" "$(dir_size "$BUILDX_REFS_DIR")" clean
        report_row "Docker images (all)" "$(docker_size 'Images')" clean
    else
        report_row "Dangling images ($(dangling_count))" "-" "$(pick $(( default_mode || CLEAN_IMAGES )))"
        if (( ${#DROP_IMAGES[@]} )); then
            report_row "Image tags to remove (${#DROP_IMAGES[@]})" \
                "$(human "$(images_bytes)")" "-"
            TOTAL_BYTES=$(( TOTAL_BYTES + $(images_bytes) ))
            for ref in "${DROP_IMAGES[@]}"; do
                printf '    %-66s %10s\n' "$ref" "$(drop_size "$ref")"
            done
        elif (( default_mode || CLEAN_IMAGES )); then
            report_row "Images to remove" "0B" "-"
        fi
    fi
    echo "-----------------------------------------------------------------------------"
    echo "To free: ~$(human "$TOTAL_BYTES")   |   Free on / now: $(disk_free)"
    if (( ${#DROP_IMAGES[@]} )); then
        echo "Image sizes are unique sizes: a lower bound, layers shared only among"
        echo "removed images are freed too."
    fi
    if (( NUKE )); then
        echo "Images and build cache share snapshots in the containerd store, so the"
        echo "real total is lower than their sum."
    fi
    if (( DRY_RUN )); then
        echo "Mode: DRY-RUN (nothing will be deleted)"
    fi
    echo "-----------------------------------------------------------------------------"
}

# =============================================================================
# Cleaners
# =============================================================================

stop_devpi() {
    if ! devpi_is_running; then
        return 0
    fi
    echo "==> stopping the local package servers ($DEVPI_COMPOSE_PROJECT)"
    # stop_pypi.sh runs 'compose down': containers and network go, the bind
    # mounted data stays.
    "${JC_REPO}/stop_pypi.sh" >/dev/null
    echo "    stopped. Restart them with: ${JC_REPO}/launch_pypi.sh"
}

stop_all_containers() {
    local -a ids

    echo "==> stopping and removing all containers"
    # 'docker stop' with no arguments exits 1 under 'set -e'.
    mapfile -t ids < <(docker ps -q 2>/dev/null)
    if (( ${#ids[@]} )); then
        docker stop "${ids[@]}" >/dev/null
    fi
    docker container prune -f 2>&1 | tail -1
}

clean_host_caches() {
    echo "==> uv"
    if is_bounded_dir "$UV_CACHE_DIR" "$HOME/.cache"; then
        if command -v uv >/dev/null 2>&1; then
            UV_CACHE_DIR="$UV_CACHE_DIR" uv cache clean >/dev/null 2>&1 \
                || remove_dir "$UV_CACHE_DIR"
        else
            remove_dir "$UV_CACHE_DIR"
        fi
        echo "    OK"
    fi
    echo "==> pip"
    if is_bounded_dir "$PIP_CACHE_DIR" "$HOME/.cache"; then
        if command -v pip3 >/dev/null 2>&1; then
            PIP_CACHE_DIR="$PIP_CACHE_DIR" pip3 cache purge >/dev/null 2>&1 \
                || remove_dir "$PIP_CACHE_DIR"
        else
            remove_dir "$PIP_CACHE_DIR"
        fi
        echo "    OK"
    fi
}

clean_dangling() {
    echo "==> dangling images"
    docker image prune -f 2>&1 | tail -1
}

remove_images() {
    local ref failed=0

    echo "==> removing ${#DROP_IMAGES[@]} image tag(s)"
    # By tag, without -f: an id still tagged elsewhere only loses this name,
    # and an image a container uses is refused instead of forced.
    for ref in "${DROP_IMAGES[@]}"; do
        if ! docker image rm "$ref" >/dev/null 2>&1; then
            echo "    FAILED  $ref (in use by a container?)"
            failed=$(( failed + 1 ))
        fi
    done
    echo "    removed $(( ${#DROP_IMAGES[@]} - failed )), failed $failed"
}

clean_buildkit_unused() {
    # LastUsedAt of every record a build loads, cache hits included, is bumped
    # to the build time, so the chain's records are all newer than its start.
    # Without -a, internal/frontend records and records shared with images are
    # kept as well; the ccache mount is excluded by type.
    local secs=$(( $(date +%s) - CHAIN_ANCHOR + CACHE_GRACE_SECONDS ))

    echo "==> BuildKit records not used since $(date -d "@$(( CHAIN_ANCHOR - CACHE_GRACE_SECONDS ))" '+%F %T')"
    docker buildx prune -f --filter "until=${secs}s" \
        --filter 'type!=exec.cachemount' 2>&1 | tail -1
}

restart_docker() {
    local waited=0

    echo "==> restarting the docker daemon"
    if ! run_root systemctl restart docker; then
        echo "    FAILED  could not restart docker.service"
        return 1
    fi
    # The API socket can lag behind the unit becoming active.
    until docker info >/dev/null 2>&1; do
        if (( waited >= DOCKER_READY_TIMEOUT )); then
            echo "    FAILED  daemon not answering after ${DOCKER_READY_TIMEOUT}s"
            return 1
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    echo "    OK"
}

verify_buildkit() {
    # After a full prune anything left is in use; only a daemon restart drops
    # those references, and only when the leftover is worth it.
    local leftover

    leftover="$(buildkit_total_bytes)"
    if (( leftover <= BUILDKIT_LEFTOVER_MIN_BYTES )); then
        echo "    verified: $(human "$leftover") of build cache left"
        return 0
    fi
    echo "    WARNING  $(human "$leftover") of build cache survived the prune (in use)."
    if ! can_restart_docker || ! restart_docker; then
        BUILDKIT_STUCK=1
        return 0
    fi
    echo "==> BuildKit build cache, second pass"
    docker buildx prune -af 2>&1 | tail -1 || true
    leftover="$(buildkit_total_bytes)"
    if (( leftover > BUILDKIT_LEFTOVER_MIN_BYTES )); then
        echo "    WARNING  $(human "$leftover") still in use after the restart"
        BUILDKIT_STUCK=1
        return 0
    fi
    echo "    verified: $(human "$leftover") of build cache left"
}

clean_buildkit_all() {
    echo "==> BuildKit build cache (all, ccache mount included)"
    docker buildx prune -af 2>&1 | tail -1
    verify_buildkit
}

clean_nuke() {
    echo "==> NUKE: build history, images, build cache, networks, volumes"
    # Each step is guarded so 'pipefail' never skips the later passes. History
    # records hold logs and provenance blobs no prune reaches.
    docker buildx history rm --all >/dev/null 2>&1 || true
    if is_bounded_dir "$BUILDX_REFS_DIR" "$HOME/.docker/buildx"; then
        remove_dir "$BUILDX_REFS_DIR"
    fi
    docker buildx prune -af           2>&1 | tail -1 || true
    docker system prune -af --volumes 2>&1 | tail -1 || true
    # 'system prune --volumes' removes anonymous volumes only.
    docker volume prune -af           2>&1 | tail -1 || true
    verify_buildkit
}

report_end() {
    local count

    echo "-----------------------------------------------------------------------------"
    if (( NUKE || CLEAN_CACHE || CLEAN_IMAGES )); then
        count="$(containerd_snapshot_count)"
        if [[ "$count" == "-" ]]; then
            echo "containerd snapshots: not read (needs root):" \
                 "sudo ctr -n $CONTAINERD_NAMESPACE snapshots ls | wc -l"
        else
            echo "containerd snapshots ($CONTAINERD_NAMESPACE): $count"
        fi
    fi
    echo "Free on / after: $(disk_free)"
    if (( BUILDKIT_STUCK )); then
        echo "WARNING  build cache is still held in use by BuildKit; that space was NOT freed."
        echo "         With no build running: sudo systemctl restart docker && $0 --cache"
        echo "         Inspect it with: docker buildx du --verbose --filter inuse"
    fi
}

# =============================================================================
# Argument parser
# =============================================================================

parse_args() {
    while (( $# )); do
        case "$1" in
            --cache)        CLEAN_CACHE=1 ;;
            --images)       CLEAN_IMAGES=1 ;;
            --nuke)         NUKE=1 ;;
            --dry-run)      DRY_RUN=1 ;;
            -h|--help)      usage ;;
            *)
                echo "Unknown argument: $1"
                echo "  Use --help to see the options."
                exit 1
                ;;
        esac
        shift
    done
    if (( NUKE )); then
        CLEAN_CACHE=0
        CLEAN_IMAGES=0
    fi
    return 0
}

# =============================================================================
# Execution
# =============================================================================

main() {
    local default_mode

    parse_args "$@"
    default_mode=$(( ! CLEAN_CACHE && ! CLEAN_IMAGES && ! NUKE ))

    require_command docker
    require_command df
    require_command du
    require_command awk
    require_command date

    if (( default_mode || CLEAN_IMAGES )); then
        load_images
    fi
    if (( default_mode )); then
        find_chain
        check_chain
        if (( CHAIN_OK )); then
            select_old_images
        fi
    elif (( CLEAN_IMAGES )); then
        select_stage_images
    fi

    print_targets
    if (( DRY_RUN )); then
        echo "DRY-RUN: no action taken."
        exit 0
    fi

    if (( NUKE )); then
        stop_devpi
        stop_all_containers
        clean_host_caches
        clean_nuke
        report_end
        return 0
    fi

    stop_devpi
    if (( default_mode || CLEAN_CACHE )); then
        clean_host_caches
    fi
    if (( default_mode || CLEAN_IMAGES )); then
        clean_dangling
        if (( ${#DROP_IMAGES[@]} )); then
            remove_images
        fi
    fi
    if (( default_mode && CHAIN_OK )); then
        clean_buildkit_unused
    fi
    if (( CLEAN_CACHE )); then
        clean_buildkit_all
    fi
    report_end
}

main "$@"
