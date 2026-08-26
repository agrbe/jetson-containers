#!/usr/bin/env bash
# =============================================================================
# publish.sh
# Publishes locally built artifacts to the local package servers:
#   - wheels   -> devpi                (POST, legacy PyPI upload API)
#   - tarballs -> nginx/WebDAV APT     (PUT)
#
# For every artifact the local copy is compared against what the server already
# holds, by sha256 plus size and date:
#   - absent on the server -> uploaded
#   - identical            -> skipped, nothing is sent
#   - different            -> both sides are printed and you choose which to keep
#
# Goals:
# - Take every setting from .env; the script defines no version fallbacks of
#   its own, so what it publishes always matches what the build resolved.
# - Derive the per-architecture index paths the same way the build does, so a
#   published artifact lands exactly where packages/cuda/cuda/config.py looks
#   for it.
# - Depend on nothing beyond curl: a fresh clone can publish before any image
#   exists.
# - Never overwrite a divergent remote artifact without an explicit decision.
#
# Usage:
#   ./publish.sh                 # publish wheels and tarballs
#   ./publish.sh --wheels        # wheels only
#   ./publish.sh --tarballs      # tarballs only
#   ./publish.sh --dry-run       # report decisions without sending anything
#   ./publish.sh --keep-local    # on conflict, always overwrite the server
#   ./publish.sh --keep-remote   # on conflict, always keep the server copy
#
# Required in .env:
#   DIST_DIR              directory holding wheel/ and tarball/
#   L4T_VERSION           e.g. 39.2   -> JetPack major for the index path
#   CUDA_VERSION          e.g. 13.2   -> cu132
#   LSB_RELEASE           e.g. 24.04  -> APT path suffix
#
# Written by launch_pypi.sh into .env (no need to set by hand):
#   DEVPI_URL, LOCAL_TAR_INDEX_URL, PIP_UPLOAD_PASS
#
# Optional variables:
#   ENV_FILE=./.env       -> configuration file sourced at startup
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
JC_REPO="${JC_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENV_FILE="${ENV_FILE:-${JC_REPO}/.env}"

# --- Behavior flags -----------------------------------------------------------
PUBLISH_WHEELS=1
PUBLISH_TARBALLS=1
DRY_RUN=0
CONFLICT_POLICY=ask     # ask | local | remote
FAILURES=0
SKIPPED=0
UPLOADED=0
# ──────────────────────────────────────────────────────────────────────────────

# =============================================================================
# Helper functions
# =============================================================================

usage() {
    sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

require_command() {
    local cmd="$1"

    # Checking tools upfront keeps failures clear and avoids partial uploads.
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Comando obrigatório não encontrado: $cmd"
        exit 1
    fi
}

require_var() {
    local name="$1"

    # Everything comes from .env on purpose: a fallback baked into this script
    # could publish to a path the build never reads.
    if [[ -z "${!name:-}" ]]; then
        echo "❌ $name não definida. Adicione ao $ENV_FILE."
        exit 1
    fi
}

load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "❌ Arquivo de configuração não encontrado: $ENV_FILE"
        exit 1
    fi

    # Auto-export only while sourcing, so the settings reach curl without
    # requiring 'export' lines inside .env itself.
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
}

jetpack_major() {
    # Mirrors the L4T -> JetPack mapping in jetson_containers/l4t_version.py.
    local major="${L4T_VERSION%%.*}"

    if (( major >= 38 )); then echo 7
    elif (( major >= 36 )); then echo 6
    elif (( major >= 34 )); then echo 5
    else echo 4
    fi
}

resolve_dist_dir() {
    # A relative DIST_DIR is resolved against the repository root, so .env can
    # ship a path that works on any clone instead of one machine's absolute
    # layout. An absolute path is left untouched.
    if [[ "$DIST_DIR" != /* ]]; then
        DIST_DIR="${JC_REPO}/${DIST_DIR}"
    fi
}

resolve_paths() {
    # Reproduces packages/cuda/cuda/config.py:140-148. The APT path gains the
    # Ubuntu release only from 24.04 onwards; earlier releases keep it bare.
    local apt_path
    PIP_PATH="jp$(jetpack_major)/cu${CUDA_VERSION//./}"

    if (( ${LSB_RELEASE%%.*} >= 24 )); then
        apt_path="${PIP_PATH}/${LSB_RELEASE}"
    else
        apt_path="${PIP_PATH}"
    fi

    DEVPI_UPLOAD_URL="${DEVPI_URL}/${PIP_PATH}/"
    DEVPI_SIMPLE_URL="${DEVPI_URL}/${PIP_PATH}/+simple"
    APT_UPLOAD_URL="${LOCAL_TAR_INDEX_URL}/${apt_path}"

    # devpi user matches PIP_UPLOAD_USER in config.py:200-203 (jp6/jp7/sbsa).
    UPLOAD_USER="${PIP_UPLOAD_USER:-jp$(jetpack_major)}"

    WHEEL_DIR="${DIST_DIR%/}/wheel"
    TARBALL_DIR="${DIST_DIR%/}/tarball"
}

server_is_up() {
    curl -sf --max-time 5 "$1" >/dev/null 2>&1
}

check_servers() {
    local ok=1

    if (( PUBLISH_WHEELS )) && ! server_is_up "${DEVPI_URL}/+api"; then
        echo "❌ devpi não responde em ${DEVPI_URL}"
        ok=0
    fi

    if (( PUBLISH_TARBALLS )) && ! server_is_up "${LOCAL_TAR_INDEX_URL}/"; then
        echo "❌ servidor APT não responde em ${LOCAL_TAR_INDEX_URL}"
        ok=0
    fi

    if (( ! ok )); then
        echo "   Suba os servidores com: ${JC_REPO}/launch_pypi.sh"
        exit 1
    fi
}

print_config() {
    echo "-----------------------------------------------------------------------------"
    echo "Origem:   $DIST_DIR"
    echo "Wheels:   ${DEVPI_UPLOAD_URL} (usuário: ${UPLOAD_USER})"
    echo "Tarballs: ${APT_UPLOAD_URL}"
    echo "Alvo:     L4T=${L4T_VERSION} CUDA=${CUDA_VERSION} Ubuntu=${LSB_RELEASE}"
    case "$CONFLICT_POLICY" in
        local)  echo "Conflito: sobrescrever com o local (--keep-local)" ;;
        remote) echo "Conflito: manter o remoto (--keep-remote)" ;;
    esac
    (( DRY_RUN )) && echo "Modo:     DRY-RUN (nada será enviado)"
    echo "-----------------------------------------------------------------------------"
}

verify_manifest() {
    local manifest="${DIST_DIR%/}/MANIFEST.sha256"

    # Optional: a dist/ assembled by hand may not have one, and each tarball
    # still carries its own .sha256 sidecar.
    if [[ ! -f "$manifest" ]]; then
        echo "⚠️  MANIFEST.sha256 ausente — pulando verificação global"
        return 0
    fi

    echo "==> Verificando MANIFEST.sha256..."
    if ( cd "$DIST_DIR" && sha256sum --check --quiet MANIFEST.sha256 ); then
        echo "    OK"
    else
        echo "❌ Checksums divergem. Publicação abortada."
        exit 1
    fi
}

# =============================================================================
# Metadata collection
# =============================================================================

local_meta() {
    local file="$1"

    LOCAL_SHA="$(sha256sum "$file" | awk '{print $1}')"
    LOCAL_SIZE="$(stat -c '%s' "$file")"
    # Same format as the HTTP Last-Modified header, so both sides read alike.
    LOCAL_DATE="$(date -u -d "@$(stat -c '%Y' "$file")" '+%a, %d %b %Y %H:%M:%S GMT')"
}

read_head() {
    local url="$1"
    local headers

    headers="$(curl -sfI "$url" 2>/dev/null)" || return 1
    REMOTE_SIZE="$(printf '%s' "$headers" | grep -i '^content-length:' | tr -d '\r' | awk '{print $2}')"
    REMOTE_DATE="$(printf '%s' "$headers" | grep -i '^last-modified:' | tr -d '\r' | cut -d' ' -f2-)"
}

remote_wheel_meta() {
    local project="$1"
    local base="$2"
    local href fname

    REMOTE_SHA=""; REMOTE_SIZE=""; REMOTE_DATE=""; REMOTE_URL=""

    # devpi puts the full digest in the PEP 503 fragment, so no JSON parsing
    # and no python dependency is needed to read it.
    while IFS= read -r href; do
        fname="${href##*/}"
        fname="${fname%%#*}"
        [[ "$fname" == "$base" ]] || continue

        REMOTE_SHA="${href##*#sha256=}"
        # Links are relative to the index root ('../../+f/...').
        REMOTE_URL="${DEVPI_URL}/${PIP_PATH}/${href#../../}"
        REMOTE_URL="${REMOTE_URL%%#*}"
        read_head "$REMOTE_URL" || true
        return 0
    done < <(curl -sf "${DEVPI_SIMPLE_URL}/${project}/" 2>/dev/null \
             | grep -oE 'href="[^"]+"' | sed 's/^href="//; s/"$//')

    return 1
}

remote_tarball_meta() {
    local url="$1"
    local sha_url="$2"

    REMOTE_SHA=""; REMOTE_SIZE=""; REMOTE_DATE=""; REMOTE_URL="$url"

    read_head "$url" || return 1

    # The sidecar holds "<sha256>  <filename>"; it may be missing even when the
    # tarball is present, in which case size/date still drive the report.
    REMOTE_SHA="$(curl -sf "$sha_url" 2>/dev/null | awk '{print $1}')" || true
    return 0
}

# =============================================================================
# Decision
# =============================================================================

decide() {
    # Sets DECISION to 'upload' or 'skip' by comparing the local artifact with
    # whatever the server already holds.
    local label="$1"
    local present="$2"
    local answer

    if (( ! present )); then
        echo "    ${label}: ausente no servidor → enviar"
        DECISION=upload
        return 0
    fi

    if [[ -n "$REMOTE_SHA" && "$REMOTE_SHA" == "$LOCAL_SHA" ]]; then
        echo "    ${label}: idêntico → nada a fazer"
        DECISION=skip
        return 0
    fi

    echo "    ${label}: ⚠️  DIVERGENTE"
    printf '        %-7s sha256=%s…  %12s bytes  %s\n' \
        "local"  "${LOCAL_SHA:0:16}"  "$LOCAL_SIZE"  "$LOCAL_DATE"
    printf '        %-7s sha256=%s…  %12s bytes  %s\n' \
        "remoto" "${REMOTE_SHA:0:16}" "${REMOTE_SIZE:-?}" "${REMOTE_DATE:-?}"

    case "$CONFLICT_POLICY" in
        local)
            echo "        --keep-local → sobrescrever o remoto"
            DECISION=upload
            return 0
            ;;
        remote)
            echo "        --keep-remote → manter o remoto"
            DECISION=skip
            return 0
            ;;
    esac

    if (( DRY_RUN )); then
        echo "        [dry-run] exigiria decisão manual"
        DECISION=skip
        return 0
    fi

    # Read from the terminal, not stdin, so the prompt still works when the
    # script's output is piped. A '-r' test is not enough: /dev/tty exists and
    # looks readable even with no controlling terminal, and only the open
    # fails — so open it explicitly and bail out if that is not possible.
    if ! ( : </dev/tty ) 2>/dev/null; then
        echo "❌ Conflito sem terminal para perguntar. Use --keep-local ou --keep-remote."
        exit 1
    fi
    exec 3</dev/tty

    while true; do
        read -r -u 3 -p "        Manter qual? [l]ocal / [r]emoto / [a]bortar: " answer
        case "${answer,,}" in
            l|local)         exec 3<&-; DECISION=upload; return 0 ;;
            r|remoto|remote) exec 3<&-; DECISION=skip;   return 0 ;;
            a|abortar|abort) exec 3<&-; echo "❌ Abortado pelo usuário."; exit 1 ;;
            *) echo "        Responda l, r ou a." ;;
        esac
    done
}

# =============================================================================
# Wheels
# =============================================================================

normalize_project() {
    # PEP 503: the index keys projects with '-' separators, lowercased.
    echo "$1" | tr '[:upper:]_.' '[:lower:]--'
}

upload_wheel() {
    local wheel="$1"
    local base="${wheel##*/}"
    local stem="${base%.whl}"
    local -a parts
    local name version pyver project present=0

    # PEP 427 filename: {dist}-{version}(-{build})?-{python}-{abi}-{platform}.
    # The distribution never contains '-' (it is escaped to '_'), so the first
    # two fields are unambiguous and the python tag is third from the end.
    IFS='-' read -r -a parts <<< "$stem"
    name="${parts[0]}"
    version="${parts[1]}"
    pyver="${parts[${#parts[@]}-3]}"
    project="$(normalize_project "$name")"

    local_meta "$wheel"
    remote_wheel_meta "$project" "$base" && present=1

    decide "$base" "$present"
    if [[ "$DECISION" == "skip" ]]; then
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    if (( DRY_RUN )); then
        echo "        [dry-run] POST ${base} (name=${name} version=${version})"
        return 0
    fi

    # devpi speaks the legacy PyPI upload API, so curl is enough — no twine,
    # and therefore no dependency on an image that may not exist yet.
    if ! curl -sf -u "${UPLOAD_USER}:${PIP_UPLOAD_PASS}" \
        -F ":action=file_upload" \
        -F "protocol_version=1" \
        -F "metadata_version=2.1" \
        -F "name=${name}" \
        -F "version=${version}" \
        -F "filetype=bdist_wheel" \
        -F "pyversion=${pyver}" \
        -F "content=@${wheel}" \
        "$DEVPI_UPLOAD_URL" >/dev/null; then
        echo "        FALHOU  upload de ${base}"
        FAILURES=$((FAILURES + 1))
        return 0
    fi

    # Re-read the index to confirm the digest the server now serves is ours.
    if remote_wheel_meta "$project" "$base" && [[ "$REMOTE_SHA" == "$LOCAL_SHA" ]]; then
        echo "        OK  ${base}"
        UPLOADED=$((UPLOADED + 1))
    else
        echo "        FALHOU  ${base} enviado mas o índice não serve o mesmo sha256"
        FAILURES=$((FAILURES + 1))
    fi
}

publish_wheels() {
    local -a wheels=()
    local wheel

    if [[ ! -d "$WHEEL_DIR" ]]; then
        echo "⚠️  $WHEEL_DIR não existe — nenhuma wheel para publicar"
        return 0
    fi

    # nullglob keeps an unmatched pattern from becoming a literal filename.
    shopt -s nullglob
    wheels=("$WHEEL_DIR"/*.whl)
    shopt -u nullglob

    if (( ${#wheels[@]} == 0 )); then
        echo "⚠️  Nenhuma wheel em $WHEEL_DIR"
        return 0
    fi

    echo "==> ${#wheels[@]} wheel(s) em ${DEVPI_UPLOAD_URL}"
    for wheel in "${wheels[@]}"; do
        upload_wheel "$wheel"
    done
}

# =============================================================================
# Tarballs
# =============================================================================

put_file() {
    local src="$1"
    local url="$2"

    # nginx has create_full_put_path on, so the target directory is created by
    # the upload itself when it does not exist yet.
    if ! curl -sf -T "$src" "$url"; then
        echo "        FALHOU  PUT de ${src##*/}"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    # Re-read to confirm the file is actually served, not just accepted.
    if ! curl -sfI "$url" >/dev/null; then
        echo "        FALHOU  ${src##*/} aceito no PUT mas não é servido"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    echo "        OK  ${src##*/}"
    return 0
}

publish_tarball() {
    local tarball="$1"
    local base="${tarball##*/}"
    local sha="${tarball%.tar.gz}.sha256"
    local present=0

    # tarpack downloads the pair, so a tarball without its sidecar would fail
    # on install even though the upload succeeded.
    if [[ ! -f "$sha" ]]; then
        echo "    ${base}: PULADO — falta ${sha##*/}"
        FAILURES=$((FAILURES + 1))
        return 0
    fi

    local_meta "$tarball"
    remote_tarball_meta "${APT_UPLOAD_URL}/${base}" "${APT_UPLOAD_URL}/${sha##*/}" && present=1

    decide "$base" "$present"
    if [[ "$DECISION" == "skip" ]]; then
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    if (( DRY_RUN )); then
        echo "        [dry-run] PUT ${base} + ${sha##*/}"
        return 0
    fi

    # The sidecar always travels with the tarball; publishing one without the
    # other leaves the pair inconsistent.
    if put_file "$tarball" "${APT_UPLOAD_URL}/${base}" \
        && put_file "$sha" "${APT_UPLOAD_URL}/${sha##*/}"; then
        UPLOADED=$((UPLOADED + 1))
    fi
}

publish_tarballs() {
    local -a tarballs=()
    local tarball

    if [[ ! -d "$TARBALL_DIR" ]]; then
        echo "⚠️  $TARBALL_DIR não existe — nenhum tarball para publicar"
        return 0
    fi

    shopt -s nullglob
    tarballs=("$TARBALL_DIR"/*.tar.gz)
    shopt -u nullglob

    if (( ${#tarballs[@]} == 0 )); then
        echo "⚠️  Nenhum tarball em $TARBALL_DIR"
        return 0
    fi

    echo "==> ${#tarballs[@]} tarball(s) em ${APT_UPLOAD_URL}"
    for tarball in "${tarballs[@]}"; do
        publish_tarball "$tarball"
    done
}

# =============================================================================
# Argument parser
# =============================================================================

parse_args() {
    while (( $# )); do
        case "$1" in
            --wheels)      PUBLISH_TARBALLS=0 ;;
            --tarballs)    PUBLISH_WHEELS=0 ;;
            --dry-run)     DRY_RUN=1 ;;
            --keep-local)  CONFLICT_POLICY=local ;;
            --keep-remote) CONFLICT_POLICY=remote ;;
            -h|--help)     usage ;;
            *)
                echo "❌ Argumento desconhecido: $1"
                echo "   Use --help para ver as opções."
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

    require_command curl
    require_command sha256sum

    load_env

    require_var DIST_DIR
    require_var L4T_VERSION
    require_var CUDA_VERSION
    require_var LSB_RELEASE
    (( PUBLISH_WHEELS ))   && { require_var DEVPI_URL; require_var PIP_UPLOAD_PASS; }
    (( PUBLISH_TARBALLS )) && require_var LOCAL_TAR_INDEX_URL

    resolve_dist_dir

    if [[ ! -d "$DIST_DIR" ]]; then
        echo "❌ DIST_DIR não é um diretório: $DIST_DIR"
        exit 1
    fi

    resolve_paths
    check_servers
    print_config
    verify_manifest

    (( PUBLISH_WHEELS ))   && publish_wheels
    (( PUBLISH_TARBALLS )) && publish_tarballs

    echo "-----------------------------------------------------------------------------"
    echo "Enviados: ${UPLOADED}   Inalterados: ${SKIPPED}   Falhas: ${FAILURES}"
    if (( FAILURES )); then
        echo "❌ Concluído com falhas."
        exit 1
    fi
    echo "✅ Publicação concluída."
}

main "$@"
