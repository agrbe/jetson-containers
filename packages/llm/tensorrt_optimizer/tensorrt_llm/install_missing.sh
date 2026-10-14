#!/usr/bin/env bash
# Install only the requirements whose distribution is not in the image yet.
# TensorRT-LLM pins many common libraries (pillow, scipy, urllib3, onnx...) to
# older versions; reinstalling them would downgrade what earlier stages
# installed and tested. Option lines (--extra-index-url, ...) are kept.
#
# Usage: install_missing.sh requirements.txt [extra uv pip install args]
set -euo pipefail

req_file="$1"
shift

norm() { tr 'A-Z_.' 'a-z--'; }

installed=$(uv pip freeze | sed -E 's/[ =@;].*//' | norm)
# next to the original so relative '-c constraints.txt' / '-r other.txt' still resolve
missing="$(dirname "$req_file")/.missing-$(basename "$req_file")"

sed -E 's/\s+#.*//' "$req_file" | while read -r line; do
    [ -z "$line" ] || [[ "$line" == \#* ]] && continue
    if [[ "$line" == -* ]]; then
        echo "$line"
        continue
    fi
    name=$(printf '%s' "$line" | sed -E 's/^([A-Za-z0-9_.-]+).*/\1/' | norm)
    if grep -qx "$name" <<< "$installed"; then
        echo "keeping installed ${name} (requested: ${line})" >&2
    else
        echo "$line"
    fi
done > "$missing"

echo "== installing missing requirements from ${req_file}:"
cat "$missing"
if grep -qvE '^\s*-' "$missing"; then
    uv pip install -r "$missing" "$@"
fi
rm -f "$missing"
