#!/usr/bin/env bash
# =============================================================================
# export_image.sh
# Exports a local Docker image to a tar archive with integrity data.
#
# Goals:
# - Record the image identity (content-addressed Id) before exporting.
# - Stream `docker save` straight to disk; no extra compression, because the
#   containerd image store already exports gzip-compressed layer blobs
#   (measured: zstd on top gained ~0% at the same export time).
# - Write a sha256 checksum that `sha256sum -c` can verify at the destination.
# - Never leave a partial archive behind when the export fails.
#
# Usage:
#   ./export_image.sh <image[:tag]> [--output <dir>]
#
# Outputs (in <output dir>/<name>/, output dir defaults to the current directory):
#   <name>.tar              -> `docker save` stream (loadable with docker load -i)
#   <name>.tar.sha256       -> transport checksum (relative filename)
#   <name>.id               -> image Id; compare after `docker load`
#
# Progress:
#   With `pv` installed (apt install pv), shows percentage, throughput and ETA.
#   Without it, the export runs silently until it finishes.
#   The total comes from the compressed content size (containerd image store,
#   via the Engine API, needs curl + python3) or from the uncompressed layer
#   size (classic store). When no estimate is available, pv runs without a
#   total instead of showing a wrong percentage.
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
# --- Arguments (filled by the parser) -----------------------------------------
IMAGE=""
OUTPUT_DIR="."

# --- Runtime state ------------------------------------------------------------
PARTIAL_FILE=""     # removed by the cleanup trap on failure
CREATED_DIR=""      # per-image dir created by this run; removed on failure if left empty
STREAM_SIZE=""      # estimated docker save stream length (bytes); empty = unknown
SIZE_SOURCE=""      # where the estimate came from, shown in the config print
# ──────────────────────────────────────────────────────────────────────────────

# =============================================================================
# Helper functions
# =============================================================================

usage() {
    echo "Usage: $(basename "$0") <image[:tag]> [--output <dir>]"
    echo ""
    echo "  <image[:tag]>        local Docker image to export"
    echo "  -o, --output <dir>   output directory (default: current directory)"
    echo "  -h, --help           show this help"
}

require_command() {
    local cmd="$1"

    # Checking tools upfront avoids discovering a missing tool after
    # docker save has already streamed gigabytes.
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Required command not found: $cmd"
        exit 1
    fi
}

cleanup_partial() {
    # An interrupted or failed export must not leave a truncated archive that
    # could later be mistaken for a valid one.
    if [[ -n "$PARTIAL_FILE" && -f "$PARTIAL_FILE" ]]; then
        rm -f "$PARTIAL_FILE"
        echo "🧹 Removed partial file: $PARTIAL_FILE"
    fi

    # Only a directory this run created, and only when nothing ended up in it,
    # is removed; an existing per-image directory is never touched.
    if [[ -n "$CREATED_DIR" && -d "$CREATED_DIR" ]]; then
        rmdir "$CREATED_DIR" 2>/dev/null || true
    fi
}

sanitize_name() {
    local image="$1"

    # Image references contain '/' and ':' which are invalid or awkward in
    # filenames; map both to '_' so the archive name stays traceable.
    printf '%s' "$image" | tr '/:' '__'
}

print_config() {
    local image_id="$1"
    local base_name="$2"

    echo "-----------------------------------------------------------------------------"
    echo "Image:      $IMAGE"
    echo "Id:         $image_id"
    echo "Output:     $OUTPUT_DIR/$base_name/$base_name.tar"
    if [[ -n "$STREAM_SIZE" ]]; then
        echo "Estimate:   $(numfmt --to=iec-i --suffix=B "$STREAM_SIZE") ($SIZE_SOURCE)"
    else
        echo "Estimate:   unavailable (progress without percentage)"
    fi
    echo "-----------------------------------------------------------------------------"
}

# =============================================================================
# Requirement and state checks
# =============================================================================

validate_requirements() {
    require_command docker
    require_command sha256sum
    require_command numfmt
}

validate_image() {
    # Only local images can be saved; failing here is cheaper and clearer than
    # letting docker save fail mid-stream.
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "❌ Image not found locally: $IMAGE"
        exit 1
    fi
}

prepare_output_dir() {
    mkdir -p "$OUTPUT_DIR"

    # Absolute path keeps messages unambiguous and survives the scoped cd below.
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
}

# =============================================================================
# Stream size estimation (progress bar total)
# =============================================================================

uses_containerd_store() {
    # With the containerd image store, docker save emits the layer blobs as
    # stored (already gzip-compressed); with the classic store it emits
    # uncompressed layer tars. The two cases need different size sources.
    docker info --format '{{.DriverStatus}}' 2>/dev/null | grep -q 'io.containerd.snapshotter'
}

docker_socket_path() {
    # Honor DOCKER_HOST when it points at a unix socket; default otherwise.
    if [[ "${DOCKER_HOST:-}" == unix://* ]]; then
        printf '%s' "${DOCKER_HOST#unix://}"
    else
        printf '%s' "/var/run/docker.sock"
    fi
}

containerd_content_size() {
    local api_version socket

    # The per-manifest compressed content size is only exposed by the Engine
    # API (images/{name}/json?manifests=1, API >= 1.48), not by the CLI.
    api_version="$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null)" || return 1
    socket="$(docker_socket_path)"

    curl -fsS --unix-socket "$socket" \
        "http://localhost/v${api_version}/images/${IMAGE}/json?manifests=1" 2>/dev/null \
        | python3 -c '
import json, sys

data = json.load(sys.stdin)
manifests = data.get("Manifests") or []

# docker save exports every locally available image manifest, so the stream
# carries the sum of their compressed content (layers + config + manifest).
total = sum(
    (m.get("Size") or {}).get("Content", 0)
    for m in manifests
    if m.get("Kind") == "image" and m.get("Available")
)
if total <= 0:
    sys.exit(1)
print(total)
'
}

estimate_stream_size() {
    local size

    # Prints "<bytes> <source>" on success; prints nothing when no reliable
    # estimate exists, so the caller can run pv without a total instead of
    # showing a misleading percentage.
    if uses_containerd_store; then
        if size="$(containerd_content_size)"; then
            printf '%s %s' "$size" "containerd compressed content"
        fi
    else
        size="$(docker image inspect --format '{{.Size}}' "$IMAGE" 2>/dev/null)" || return 0
        if [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]]; then
            printf '%s %s' "$size" "uncompressed layers (classic store)"
        fi
    fi
}

# =============================================================================
# Export stages
# =============================================================================

record_image_id() {
    local image_id="$1"
    local id_file="$2"

    # The Id is the sha256 of the image config, which transitively covers every
    # layer. It is captured before the export (so a retag during the export
    # cannot change it) and written only after the archive is complete, so a
    # failed run leaves no orphan .id behind.
    printf '%s\n' "$image_id" > "$id_file"
}

export_archive() {
    local archive="$1"
    local partial="${archive}.partial"

    PARTIAL_FILE="$partial"

    # pipefail makes a failure in any stage of the pipeline abort the script
    # instead of producing a valid-looking archive of a truncated stream.
    if command -v pv >/dev/null 2>&1; then
        local -a pv_args=(-f -N "export")

        # With an estimate, pv shows percentage and ETA (it may end slightly
        # past 100% because of tar headers and OCI metadata files). Without
        # one, pv still shows bytes, throughput and elapsed time.
        if [[ -n "$STREAM_SIZE" ]]; then
            pv_args+=(-s "$STREAM_SIZE")
        fi

        echo "📦 Exporting (docker save | pv)..."
        docker save "$IMAGE" | pv "${pv_args[@]}" > "$partial"
    else
        echo "📦 Exporting (docker save); install 'pv' for a progress bar..."
        docker save "$IMAGE" > "$partial"
    fi

    # Atomic rename: the final name only exists once the stream is complete.
    mv -f "$partial" "$archive"
    PARTIAL_FILE=""
}

write_checksum() {
    local archive="$1"

    echo "🔐 Computing sha256..."

    # Run inside the output dir so the checksum file stores a relative name and
    # `sha256sum -c` works wherever the pair of files is copied.
    (
        cd "$(dirname "$archive")"
        sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256"
    )
}

print_summary() {
    local archive="$1"
    local id_file="$2"

    echo ""
    echo "✅ Export complete"
    echo "   File:     $archive ($(du -h "$archive" | cut -f1))"
    echo "   sha256:   $(cut -d' ' -f1 "$archive.sha256")"
    echo "   Id:       $(cat "$id_file")"
    echo ""
    echo "On the destination (inside $(basename "$(dirname "$archive")")/):"
    echo "   sha256sum -c $(basename "$archive").sha256"
    echo "   docker load -i $(basename "$archive")"
    echo "   docker image inspect --format '{{.Id}}' $IMAGE   # must match $(basename "$id_file")"
}

# =============================================================================
# Argument parser
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "❌ --output requires a directory"
                    exit 1
                fi
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --output=*)
                OUTPUT_DIR="${1#*=}"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo "❌ Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [[ -n "$IMAGE" ]]; then
                    echo "❌ Only one image per run (also got: $1)"
                    exit 1
                fi
                IMAGE="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$IMAGE" ]]; then
        usage
        exit 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    local base_name image_dir archive id_file image_id

    parse_args "$@"
    validate_requirements
    validate_image
    prepare_output_dir

    base_name="$(sanitize_name "$IMAGE")"
    image_dir="$OUTPUT_DIR/$base_name"
    archive="$image_dir/$base_name.tar"
    id_file="$image_dir/$base_name.id"
    image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE")"

    local estimate
    estimate="$(estimate_stream_size)"
    if [[ -n "$estimate" ]]; then
        STREAM_SIZE="${estimate%% *}"
        SIZE_SOURCE="${estimate#* }"
    fi

    print_config "$image_id" "$base_name"

    # Registered before any file is created so every failure path cleans up.
    trap cleanup_partial EXIT

    # One directory per image keeps the .tar, .sha256 and .id together, which
    # is the unit that gets copied to the destination.
    if [[ ! -d "$image_dir" ]]; then
        mkdir -p "$image_dir"
        CREATED_DIR="$image_dir"
    fi

    export_archive "$archive"
    write_checksum "$archive"
    record_image_id "$image_id" "$id_file"

    # Success: the directory is now a deliverable, never cleanup material.
    CREATED_DIR=""
    print_summary "$archive" "$id_file"
}

main "$@"
