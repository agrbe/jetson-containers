#!/usr/bin/env bash
# =============================================================================
# download.sh
# Downloads the artifacts held by the local package servers into dist/:
#   - wheels   <- devpi                (only files uploaded to the index, not the
#                                       PyPI mirror)          -> dist/wheel/
#   - tarballs <- nginx/WebDAV APT     (*.tar.gz + *.sha256)   -> dist/tarball/
#
# Every file is checked against the sha256 the server publishes:
#   - absent locally       -> downloaded, then verified
#   - identical            -> skipped
#   - different            -> downloaded again and replaced
# Each file gets a sha256sum-format checksum next to it: <wheel>.whl.sha256 and
# <name>.sha256 for <name>.tar.gz. A final pass checks, for every artifact on
# the servers, that server sha256 == checksum file == sha256 of the file in
# dist/, and lists files in dist/ the servers no longer have.
#
# A file replaced by a different build with the same name is never lost: the
# previous file and its checksum move to <kind>/replaced/<YYYYMMDD_HHMMSS>/ (the
# run's start time) once the new one is verified. replaced/ is never cleaned
# automatically.
#
# Goals:
# - Resolve the index paths through the repository's own version module, so the
#   download reads exactly where the build publishes.
# - Never leave a partial or corrupt file in dist/: downloads go to a temporary
#   file and are moved into place only after the checksum matches.
#
# Usage:
#   ./download.sh                    # wheels and tarballs
#   ./download.sh --wheels           # wheels only
#   ./download.sh --tarballs         # tarballs only
#   ./download.sh --match opencv     # only files whose name contains 'opencv'
#   ./download.sh --dry-run          # report decisions without downloading
#
# Written by launch_pypi.sh into .env (no need to set by hand):
#   DEVPI_URL, LOCAL_TAR_INDEX_URL
#
# Optional variables:
#   ENV_FILE=./.env       -> configuration file sourced at startup
#   DIST_DIR=dist         -> output directory (relative to the repository root)
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
JC_REPO="${JC_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENV_FILE="${ENV_FILE:-${JC_REPO}/.env}"
# DIST_DIR given on the command line wins over the one in .env
DIST_DIR_ARG="${DIST_DIR:-}"

# --- Behavior flags -----------------------------------------------------------
GET_WHEELS=1
GET_TARBALLS=1
DRY_RUN=0
MATCH=""
FAILURES=0
SKIPPED=0
DOWNLOADED=0
# dist path -> sha256 published by the server (filled by the listings)
declare -A SERVER_SHA=()
# subdirectory of <kind>/replaced/ that receives this run's previous files
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
# ──────────────────────────────────────────────────────────────────────────────

# =============================================================================
# Helper functions
# =============================================================================

usage() {
    sed -n '3,/^# =\{10,\}/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
    exit 0
}

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd"
        exit 1
    fi
}

require_var() {
    local name="$1"

    if [[ -z "${!name:-}" ]]; then
        echo "$name is not set. Add it to $ENV_FILE (launch_pypi.sh writes it)."
        exit 1
    fi
}

load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "Configuration file not found: $ENV_FILE"
        exit 1
    fi

    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
}

resolve_from_repo() {
    # Same expressions as packages/cuda/cuda/config.py, read through the
    # repository's version module: l4t_version.py reads the host when
    # L4T_VERSION / CUDA_VERSION / LSB_RELEASE are unset and honours .env pins.
    local output
    local venv="${JC_REPO}/venv/bin/activate"

    # shellcheck disable=SC1090
    [[ -f "$venv" ]] && source "$venv"

    output="$(PYTHONPATH="$JC_REPO" python3 - 2>/dev/null <<'PY'
from jetson_containers import (
    CUDA_VERSION, LSB_RELEASE, JETPACK_VERSION, IS_TEGRA, IS_SBSA, DOCKER_ARCH)
from packaging.version import Version

short = f"cu{str(CUDA_VERSION).replace('.', '')}"
pip_path = (
    f"sbsa/{short}" if IS_SBSA
    else f"jp{JETPACK_VERSION.major}/{short}" if IS_TEGRA
    else f"{DOCKER_ARCH}/{short}")
apt_path = pip_path if Version(LSB_RELEASE).major < 24 else f"{pip_path}/{LSB_RELEASE}"

print(f"PIP_PATH={pip_path}")
print(f"APT_PATH={apt_path}")
PY
    )" || true

    # jetson_containers can fail to import and still exit 0, so check the value.
    if [[ "$output" != *PIP_PATH=* ]]; then
        echo "Could not resolve the target from $JC_REPO."
        echo "  Run 'bash install.sh' first, or set L4T_VERSION, CUDA_VERSION"
        echo "  and LSB_RELEASE in $ENV_FILE."
        exit 1
    fi

    eval "$output"
}

resolve_paths() {
    DIST_DIR="${DIST_DIR_ARG:-${DIST_DIR:-dist}}"
    if [[ "$DIST_DIR" != /* ]]; then
        DIST_DIR="${JC_REPO}/${DIST_DIR}"
    fi
    WHEEL_DIR="${DIST_DIR%/}/wheel"
    TARBALL_DIR="${DIST_DIR%/}/tarball"
    DEVPI_INDEX_URL="${DEVPI_URL}/${PIP_PATH}"
    APT_INDEX_URL="${LOCAL_TAR_INDEX_URL}/${APT_PATH}"
}

server_is_up() {
    curl -sf -o /dev/null --max-time 10 "$1"
}

sha256_of() {
    sha256sum "$1" | cut -d' ' -f1
}

checksum_path() {
    # Wheels: <file>.sha256; tarballs keep the server's <name>.sha256 naming.
    case "$1" in
        *.tar.gz) echo "${1%.tar.gz}.sha256" ;;
        *)        echo "${1}.sha256" ;;
    esac
}

write_checksum() {
    # write_checksum DEST SHA256: (re)write DEST's checksum file in sha256sum
    # format, only when DEST really hashes to SHA256.
    local dest="$1" sha="$2" sum_file
    sum_file="$(checksum_path "$dest")"

    (( DRY_RUN )) && return
    [[ -f "$dest" && "$(sha256_of "$dest")" == "$sha" ]] || return
    if [[ -f "$sum_file" && "$(cut -d' ' -f1 "$sum_file")" == "$sha" ]]; then
        return
    fi
    [[ -f "$sum_file" ]] && echo "  ~ $(basename "$sum_file"): rewritten (did not match the server)"
    echo "${sha}  $(basename "$dest")" > "$sum_file"
}

fetch() {
    # fetch URL DEST SHA256: download to a temp file, verify, then move in place.
    local url="$1" dest="$2" sha="$3"
    local name tmp

    name="$(basename "$dest")"
    if [[ -n "$MATCH" && "$name" != *"$MATCH"* ]]; then
        return
    fi

    SERVER_SHA["$dest"]="$sha"

    if [[ -f "$dest" && "$(sha256_of "$dest")" == "$sha" ]]; then
        SKIPPED=$((SKIPPED + 1))
        echo "  = $name"
        write_checksum "$dest" "$sha"
        return
    fi

    if (( DRY_RUN )); then
        if [[ -f "$dest" ]]; then
            echo "  + $name (would download; previous kept in replaced/${RUN_STAMP}/)"
        else
            echo "  + $name (would download)"
        fi
        DOWNLOADED=$((DOWNLOADED + 1))
        return
    fi

    tmp="${dest}.part"
    if ! curl -fL --retry 3 --silent --show-error -o "$tmp" "$url"; then
        echo "  ! $name: download failed"
        rm -f "$tmp"
        FAILURES=$((FAILURES + 1))
        return
    fi
    if [[ "$(sha256_of "$tmp")" != "$sha" ]]; then
        echo "  ! $name: sha256 mismatch"
        rm -f "$tmp"
        FAILURES=$((FAILURES + 1))
        return
    fi

    local kept=""
    if [[ -f "$dest" ]]; then
        keep_previous "$dest"
        kept=" (previous kept in replaced/${RUN_STAMP}/)"
    fi
    mv -f "$tmp" "$dest"
    write_checksum "$dest" "$sha"
    DOWNLOADED=$((DOWNLOADED + 1))
    echo "  + ${name}${kept}"
}

keep_previous() {
    # Move DEST and its checksum to <dir>/replaced/<RUN_STAMP>/; a missing or
    # stale checksum is recomputed so the kept copy stays verifiable.
    local dest="$1" sum_file keep_dir
    sum_file="$(checksum_path "$dest")"
    keep_dir="$(dirname "$dest")/replaced/${RUN_STAMP}"

    mkdir -p "$keep_dir"
    mv -f "$dest" "$keep_dir/"
    echo "$(sha256_of "$keep_dir/$(basename "$dest")")  $(basename "$dest")" \
        > "$keep_dir/$(basename "$sum_file")"
    rm -f "$sum_file"
}

verify_dist() {
    # Every artifact on the servers: server sha256 == checksum file == file.
    # Files in dist/ that the servers do not list are reported, not deleted.
    local dest sha sum_file actual recorded file bad=0 orphans=0

    echo "==> verifying dist/ against the servers"
    for dest in "${!SERVER_SHA[@]}"; do
        sha="${SERVER_SHA[$dest]}"
        sum_file="$(checksum_path "$dest")"
        if [[ ! -f "$dest" ]]; then
            (( DRY_RUN )) || { echo "  ! $(basename "$dest"): missing"; bad=$((bad + 1)); }
            continue
        fi
        actual="$(sha256_of "$dest")"
        recorded="$(cut -d' ' -f1 "$sum_file" 2>/dev/null || true)"
        if [[ "$actual" != "$sha" ]] && (( DRY_RUN )); then
            continue  # fetch already reported it as 'would download'
        elif [[ "$actual" != "$sha" ]]; then
            echo "  ! $(basename "$dest"): file sha256 $actual != server $sha"
            bad=$((bad + 1))
        elif [[ "$recorded" != "$sha" ]]; then
            if (( DRY_RUN )); then
                echo "  ~ $(basename "$sum_file"): ${recorded:-missing} (would write $sha)"
            else
                echo "  ! $(basename "$sum_file"): ${recorded:-missing} != server $sha"
                bad=$((bad + 1))
            fi
        fi
    done
    for file in "$WHEEL_DIR"/*.whl "$TARBALL_DIR"/*.tar.gz; do
        [[ -f "$file" ]] || continue
        [[ -n "$MATCH" && "$(basename "$file")" != *"$MATCH"* ]] && continue
        [[ -n "${SERVER_SHA[$file]+x}" ]] && continue
        # only report the kinds this run listed (--wheels / --tarballs)
        if [[ "$file" == *.whl ]] && (( ! GET_WHEELS )); then continue; fi
        if [[ "$file" == *.tar.gz ]] && (( ! GET_TARBALLS )); then continue; fi
        echo "  ? $(basename "$file"): in dist/ but not on the server"
        orphans=$((orphans + 1))
    done
    echo "    ${#SERVER_SHA[@]} checked, ${bad} mismatched, ${orphans} not on the server"
    FAILURES=$((FAILURES + bad))
}

# =============================================================================
# Artifact listings
# =============================================================================

list_wheels() {
    # One "url sha256" line per file uploaded to the index. devpi's JSON API
    # lists the index's own uploads under +links; PyPI-mirror files are not
    # included, so nothing is pulled from the mirror.
    python3 - "$DEVPI_INDEX_URL" <<'PY'
import json, sys, urllib.request

index = sys.argv[1]

def get(url):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)["result"]

for project in sorted(get(index).get("projects", [])):
    for version in get(f"{index}/{project}").values():
        for link in version.get("+links", []):
            algo, _, digest = link.get("hash_spec", "").partition("=")
            # files stored under this index (uploads), never mirror links
            if algo == "sha256" and f"{index}/+f/" in link.get("href", ""):
                print(link["href"], digest)
PY
}

list_tarballs() {
    # nginx autoindex: every *.tar.gz is published next to a *.sha256.
    curl -sf "${APT_INDEX_URL}/" | grep -oE 'href="[^"]+\.tar\.gz"' | sed -E 's/^href="(.*)"$/\1/'
}

# =============================================================================
# Downloads
# =============================================================================

download_wheels() {
    local url sha

    echo "==> wheels: ${DEVPI_INDEX_URL} -> ${WHEEL_DIR}"
    mkdir -p "$WHEEL_DIR"
    while read -r url sha; do
        [[ -n "$url" ]] && fetch "$url" "${WHEEL_DIR}/$(basename "$url")" "$sha"
    done < <(list_wheels)
}

download_tarballs() {
    local name sha

    echo "==> tarballs: ${APT_INDEX_URL} -> ${TARBALL_DIR}"
    mkdir -p "$TARBALL_DIR"
    while read -r name; do
        [[ -z "$name" ]] && continue
        if [[ -n "$MATCH" && "$name" != *"$MATCH"* ]]; then
            continue
        fi
        sha="$(curl -sf "${APT_INDEX_URL}/${name%.tar.gz}.sha256" | cut -d' ' -f1)"
        if [[ -z "$sha" ]]; then
            echo "  ! $name: no ${name%.tar.gz}.sha256 on the server"
            FAILURES=$((FAILURES + 1))
            continue
        fi
        fetch "${APT_INDEX_URL}/${name}" "${TARBALL_DIR}/${name}" "$sha"
    done < <(list_tarballs)
}

# =============================================================================
# Argument parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wheels)   GET_TARBALLS=0; shift ;;
            --tarballs) GET_WHEELS=0; shift ;;
            --match)    MATCH="${2:?--match needs a value}"; shift 2 ;;
            --dry-run)  DRY_RUN=1; shift ;;
            -h|--help)  usage ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done
}

# =============================================================================
# Execution
# =============================================================================

parse_args "$@"

require_command curl
require_command python3
require_command sha256sum

load_env
require_var DEVPI_URL
require_var LOCAL_TAR_INDEX_URL
resolve_from_repo
resolve_paths

if (( GET_WHEELS )) && ! server_is_up "${DEVPI_URL}/+api"; then
    echo "devpi is not responding at ${DEVPI_URL} (start it with launch_pypi.sh)"
    exit 1
fi
if (( GET_TARBALLS )) && ! server_is_up "${LOCAL_TAR_INDEX_URL}/"; then
    echo "APT server is not responding at ${LOCAL_TAR_INDEX_URL} (start it with launch_pypi.sh)"
    exit 1
fi

(( GET_WHEELS )) && download_wheels
(( GET_TARBALLS )) && download_tarballs
verify_dist

echo
echo "downloaded: ${DOWNLOADED}  unchanged: ${SKIPPED}  failed: ${FAILURES}$( (( DRY_RUN )) && echo '  (dry run)')"
(( FAILURES == 0 ))
